import AppKit
import CMUXMobileCore
import CmuxBrowser
import WebKit

@MainActor
extension BrowserPanel {
    static let mobileBrowserDirtyBeaconScript = """
    (() => {
      const handlerName = 'cmuxMobileBrowserStream';
      const editableFocused = () => {
        // Descend shadow roots: document.activeElement reports the shadow
        // host, and the phone keyboard must rise for widget-wrapped inputs.
        let el = document.activeElement;
        while (el && el.shadowRoot && el.shadowRoot.activeElement) el = el.shadowRoot.activeElement;
        if (!el) return false;
        const tag = String(el.tagName || '').toLowerCase();
        return !!el.isContentEditable || tag === 'textarea' ||
          (tag === 'input' && !['button','checkbox','color','file','hidden','image','radio','range','reset','submit'].includes(String(el.type || '').toLowerCase()));
      };
      const post = () => {
        try {
          window.webkit.messageHandlers[handlerName].postMessage({
            editable_focused: editableFocused()
          });
          return true;
        } catch (_) {
          return false;
        }
      };
      const existing = window.__cmuxMobileBrowserStreamBeacon;
      if (existing) {
        existing.enabled = true;
        existing.markDirty();
        return true;
      }
      // The beacon's own ticks must use the unwrapped native rAF: the public
      // requestAnimationFrame is wrapped below to detect page-driven painting
      // (canvas/WebGL), and scheduling our tick through the wrapper would mark
      // dirty forever and self-sustain the loop on an idle page.
      const nativeRequestAnimationFrame = window.requestAnimationFrame.bind(window);
      const state = {
        enabled: true,
        scheduled: false,
        pendingDirty: true,
        lastPost: 0,
        lastScrollPost: -Infinity,
        markDirty() {
          if (!this.enabled) return;
          this.pendingDirty = true;
          if (this.scheduled) return;
          this.scheduled = true;
          nativeRequestAnimationFrame(this.tick);
        },
        postScrollDirty() {
          if (!this.enabled) return;
          this.pendingDirty = true;
          const timestamp = performance.now();
          if (timestamp - this.lastScrollPost < 16) {
            this.markDirty();
            return;
          }
          this.lastScrollPost = timestamp;
          this.lastPost = timestamp;
          this.pendingDirty = false;
          if (!post()) this.enabled = false;
        },
        tick: null
      };
      const hasActivePaintSource = () => {
        try {
          if ([...document.querySelectorAll('video')].some((video) => !video.paused && !video.ended)) return true;
          return typeof document.getAnimations === 'function' &&
            document.getAnimations().some((animation) => animation.playState === 'running');
        } catch (_) {
          return false;
        }
      };
      state.tick = (timestamp) => {
        state.scheduled = false;
        if (!state.enabled) return;
        const paintsContinuously = hasActivePaintSource();
        if ((state.pendingDirty || paintsContinuously) && timestamp - state.lastPost >= 33) {
          state.lastPost = timestamp;
          state.pendingDirty = false;
          if (!post()) {
            state.enabled = false;
            return;
          }
        }
        if (state.pendingDirty || paintsContinuously) {
          state.scheduled = true;
          nativeRequestAnimationFrame(state.tick);
        }
      };
      window.__cmuxMobileBrowserStreamBeacon = state;
      // Canvas/WebGL pages repaint via their own rAF without mutating the DOM,
      // so DOM listeners and MutationObserver never see them. Wrapping the
      // public rAF marks the stream dirty whenever page code schedules a frame.
      // The wrapper stays installed after streaming stops; markDirty is a no-op
      // while disabled. Frame ids pass through, so cancelAnimationFrame works.
      window.requestAnimationFrame = (callback) => nativeRequestAnimationFrame((timestamp) => {
        state.markDirty();
        return callback(timestamp);
      });
      for (const name of ['scroll', 'wheel']) {
        addEventListener(name, () => state.postScrollDirty(), { capture: true, passive: true });
      }
      for (const name of [
        'resize', 'input', 'focusin', 'focusout',
        'play', 'pause', 'animationstart', 'animationend', 'transitionrun', 'transitionend'
      ]) {
        addEventListener(name, () => state.markDirty(), { capture: true, passive: true });
      }
      new MutationObserver(() => state.markDirty()).observe(document, {
        attributes: true,
        characterData: true,
        childList: true,
        subtree: true
      });
      state.markDirty();
      return true;
    })()
    """

    /// Replays one phone pointer input and, for clicks, moves page focus into
    /// the editable under the tap.
    ///
    /// Replayed clicks reach the page as DOM events, but WebKit refuses to
    /// move field focus for clicks in a window that is never key (the
    /// offscreen render host), so a tapped text field never focuses, the
    /// phone keyboard never rises, and backspace falls through as a
    /// page-level history-back. Programmatic JS focus is exempt from the
    /// key-window rule, so hit-test the click point and focus explicitly.
    /// - Parameter input: Page-point pointer input from the phone.
    /// - Returns: The focus-assist outcome (0 no editable, 1 focus moved,
    ///   2 already focused); 0 for non-click kinds.
    func replayMobileBrowserPointer(_ input: MobileBrowserPointerInput) async throws -> Int {
        try MobileBrowserInputReplayer().replayPointer(input, in: webView)
        guard input.kind == .click else { return 0 }
        return await assistMobileBrowserEditableFocus(atPageX: input.x, pageY: input.y)
    }

    /// Replays one phone key input unless it is a bare backspace outside an
    /// editable, which WebKit would interpret as history back-navigation.
    ///
    /// The phone keyboard's backspace is a text-editing key: with no focused
    /// editable it must be dropped, or deleting "highlighted" text navigates
    /// the page away and loses state. Modified combinations pass through.
    /// - Parameter input: A key token and modifiers from the phone.
    /// - Returns: `true` when the key was delivered, `false` when suppressed.
    func replayMobileBrowserKey(_ input: MobileBrowserKeyInput) async throws -> Bool {
        let isBareBackspace = (input.key == "delete" || input.key == "backspace")
            && input.modifiers.isEmpty
        if isBareBackspace, await mobileBrowserEditableHasFocus() == false {
            return false
        }
        try MobileBrowserInputReplayer().replayKey(input, in: webView)
        return true
    }

    /// Whether the streamed page currently focuses an editable element.
    ///
    /// `document.activeElement` reports the shadow HOST when focus sits inside
    /// a shadow root, so the check descends shadow roots to the real focused
    /// element; otherwise backspace into a widget-wrapped input would be
    /// suppressed as no-editable.
    func mobileBrowserEditableHasFocus() async -> Bool {
        let script = """
        (() => {
          const isEditable = (el) => {
            if (!el || el.nodeType !== 1) return false;
            if (el.isContentEditable) return true;
            const tag = el.tagName;
            if (tag === 'TEXTAREA' || tag === 'SELECT') return true;
            if (tag !== 'INPUT') return false;
            const type = String(el.type || 'text').toLowerCase();
            return !['button','checkbox','color','file','hidden','image','radio','range','reset','submit'].includes(type);
          };
          let el = document.activeElement;
          while (el && el.shadowRoot && el.shadowRoot.activeElement) el = el.shadowRoot.activeElement;
          return isEditable(el);
        })()
        """
        let result = try? await webView.evaluateJavaScript(script, contentWorld: .page)
        return (result as? Bool) ?? false
    }

    /// Focuses the editable element under a replayed click point.
    /// - Parameters:
    ///   - x: Click X in page viewport points.
    ///   - y: Click Y in page viewport points.
    /// - Returns: 0 when no editable is at the point, 1 when focus moved,
    ///   2 when the editable was already focused.
    func assistMobileBrowserEditableFocus(atPageX x: Double, pageY y: Double) async -> Int {
        guard x.isFinite, y.isFinite else { return 0 }
        let script = """
        (() => {
          const isEditable = (el) => {
            if (!el || el.nodeType !== 1) return false;
            if (el.isContentEditable) return true;
            const tag = el.tagName;
            if (tag === 'TEXTAREA' || tag === 'SELECT') return true;
            if (tag !== 'INPUT') return false;
            const type = String(el.type || 'text').toLowerCase();
            return !['button','checkbox','color','file','hidden','image','radio','range','reset','submit'].includes(type);
          };
          let el = document.elementFromPoint(\(x), \(y));
          // Widgets often wrap their input in a shadow root; descend one level
          // so the hit test can reach the real editable.
          if (el && el.shadowRoot) {
            const inner = el.shadowRoot.elementFromPoint(\(x), \(y));
            if (inner) el = inner;
          }
          while (el && !isEditable(el)) el = el.parentElement || (el.getRootNode && el.getRootNode().host) || null;
          if (!el) return 0;
          const deepActive = () => {
            let active = document.activeElement;
            while (active && active.shadowRoot && active.shadowRoot.activeElement) active = active.shadowRoot.activeElement;
            return active;
          };
          if (deepActive() === el) return 2;
          try { el.focus({ preventScroll: true }); } catch (_) { return 0; }
          return deepActive() === el ? 1 : 0;
        })()
        """
        let result = try? await webView.evaluateJavaScript(script, contentWorld: .page)
        return (result as? Int) ?? 0
    }

    func addMobileBrowserStreamSignalHandler(
        id handlerID: UUID,
        handler: @escaping (MobileBrowserPanelNativeSignal) -> Void
    ) {
        let wasInactive = mobileBrowserStreamSignalHandlers.isEmpty
        mobileBrowserStreamSignalHandlers[handlerID] = handler
        if wasInactive {
            // A phone mirror is a visibility touch. A session-restored or
            // memory-discarded background tab holds only a blank web shell,
            // and every capture of that shell is a white frame; without this
            // restore, only a manual reload or revealing the tab on the Mac
            // ever starts the restore navigation.
            restoreDiscardedWebViewIfNeeded(reason: "mobile_browser_stream_start")
            installMobileBrowserDirtyBeaconIfNeeded()
            reevaluateHiddenWebViewDiscardScheduling(reason: "mobile_browser_stream_started")
        }
    }

    func removeMobileBrowserStreamSignalHandler(id handlerID: UUID) {
        guard mobileBrowserStreamSignalHandlers.removeValue(forKey: handlerID) != nil else { return }
        guard mobileBrowserStreamSignalHandlers.isEmpty else { return }
        disableMobileBrowserDirtyBeacon()
        clearMobileStreamViewport()
        reevaluateHiddenWebViewDiscardScheduling(reason: "mobile_browser_stream_stopped")
    }

    /// Reflows the browser in a persistent offscreen render host at the phone's point viewport.
    @discardableResult
    func applyMobileStreamViewport(width: Int, height: Int, scale: Double) -> Bool {
        let reportedViewport = MobileBrowserViewport(width: width, height: height, scale: scale)
        if mobileBrowserStreamRenderHost != nil,
           mobileBrowserStreamViewport == reportedViewport,
           mobileBrowserStreamCanUseOffscreenRenderHost {
            return true
        }
        guard let mapping = MobileBrowserStreamViewportMapping(
            width: width,
            height: height,
            scale: scale
        ) else {
            return false
        }

        guard mobileBrowserStreamCanUseOffscreenRenderHost else {
            restoreMobileStreamPresentation(endingStream: false)
            mobileBrowserStreamViewport = reportedViewport
            publishMobileBrowserStreamSignal(.dirty(editableFocused: nil))
            return true
        }

        guard BrowserViewportLayout(
            containerBounds: CGRect(origin: .zero, size: mapping.viewport.size),
            viewport: mapping.viewport,
            pageZoom: Double(webView.pageZoom)
        ) != nil else {
            return false
        }

        if mobileBrowserStreamRenderHost == nil {
            if !mobileBrowserStreamPreviousViewportWasCaptured {
                mobileBrowserStreamPreviousViewport = viewportModel.requestedViewport
                mobileBrowserStreamPreviousViewportWasCaptured = true
            }
            mobileBrowserStreamRenderHost = BrowserOffscreenRenderHost(
                webView: webView,
                viewportSize: mapping.viewport.size
            )
        }

        viewportModel.setViewport(mapping.viewport)
        guard mobileBrowserStreamRenderHost?.resize(to: mapping.viewport.size) == true else {
            restoreMobileStreamPresentation(endingStream: false)
            mobileBrowserStreamViewport = reportedViewport
            publishMobileBrowserStreamSignal(.dirty(editableFocused: nil))
            return true
        }

        mobileBrowserStreamViewport = reportedViewport
        BrowserWindowPortalRegistry.refresh(webView: webView, reason: "mobileStreamViewport")
        publishMobileBrowserStreamSignal(.dirty(editableFocused: nil))
        return true
    }

    /// Restores the presentation hierarchy and viewport that preceded phone streaming.
    func clearMobileStreamViewport() {
        restoreMobileStreamPresentation(endingStream: true)
    }

    /// Mirrors the latest streamed frame into the Mac pane so it is not blank while
    /// the live web view renders offscreen. No-op unless the offscreen host is active.
    func updateMobileBrowserStreamMirror(_ image: NSImage) {
        mobileBrowserStreamRenderHost?.updateMirror(image)
    }

    func publishMobileBrowserStreamSignal(_ signal: MobileBrowserPanelNativeSignal) {
        for handler in mobileBrowserStreamSignalHandlers.values {
            handler(signal)
        }
    }

    func mobileBrowserStreamStateDidChange(markDirty: Bool = false) {
        guard !mobileBrowserStreamSignalHandlers.isEmpty else { return }
        publishMobileBrowserStreamSignal(.stateChanged)
        if markDirty {
            publishMobileBrowserStreamSignal(.dirty(editableFocused: nil))
        }
    }

    func mobileBrowserWebViewDidBind() {
        guard !mobileBrowserStreamSignalHandlers.isEmpty else { return }
        installMobileBrowserDirtyBeaconIfNeeded()
        mobileBrowserStreamRenderHost?.abandon()
        mobileBrowserStreamRenderHost = nil
        if let viewport = mobileBrowserStreamViewport {
            _ = applyMobileStreamViewport(
                width: viewport.width,
                height: viewport.height,
                scale: viewport.scale
            )
        } else {
            restoreMobileStreamPresentation(endingStream: false)
        }
        publishMobileBrowserStreamSignal(.webViewReplaced)
    }

    private var mobileBrowserStreamCanUseOffscreenRenderHost: Bool {
        guard !webView.cmuxIsElementFullscreenActiveOrTransitioning else { return false }
        if let host = webView.superview,
           host.browserPortalHasVisibleWebKitCompanionSubview(for: webView) {
            return false
        }
        return !viewportHostView.browserPortalHasVisibleWebKitCompanionSubview(for: webView)
    }

    private func restoreMobileStreamPresentation(endingStream: Bool) {
        let renderHost = mobileBrowserStreamRenderHost
        mobileBrowserStreamRenderHost = nil

        if mobileBrowserStreamPreviousViewportWasCaptured {
            viewportModel.setViewport(mobileBrowserStreamPreviousViewport)
        }
        renderHost?.restore()

        if mobileBrowserStreamPreviousViewportWasCaptured,
           mobileBrowserStreamPreviousViewport == nil,
           webView.cmuxBrowserViewportUsesHost,
           let nativeLayout = BrowserViewportLayout(
               containerBounds: webView.cmuxBrowserViewportContainerBounds
                   ?? CGRect(origin: .zero, size: webView.bounds.size),
               viewport: nil,
               pageZoom: Double(webView.pageZoom)
           ) {
            _ = viewportHostView.deactivateWebView(using: nativeLayout)
        }

        BrowserWindowPortalRegistry.refresh(webView: webView, reason: "mobileStreamRestore")
        if endingStream {
            mobileBrowserStreamPreviousViewport = nil
            mobileBrowserStreamPreviousViewportWasCaptured = false
            mobileBrowserStreamViewport = nil
        }
    }

    private func installMobileBrowserDirtyBeaconIfNeeded() {
        let controller = webView.configuration.userContentController
        if mobileBrowserStreamScriptInstanceID != webViewInstanceID {
            controller.addUserScript(
                WKUserScript(
                    source: Self.mobileBrowserDirtyBeaconScript,
                    injectionTime: .atDocumentStart,
                    forMainFrameOnly: true
                )
            )
            mobileBrowserStreamScriptInstanceID = webViewInstanceID
        }
        controller.removeScriptMessageHandler(forName: MobileBrowserDirtyMessageHandler.name)
        let handler = MobileBrowserDirtyMessageHandler { [weak self] editableFocused in
            self?.publishMobileBrowserStreamSignal(.dirty(editableFocused: editableFocused))
        }
        mobileBrowserStreamMessageHandler = handler
        controller.add(handler, name: MobileBrowserDirtyMessageHandler.name)
        let activeWebView = webView
        Task { @MainActor [weak activeWebView] in
            try? await activeWebView?.evaluateJavaScript(Self.mobileBrowserDirtyBeaconScript, contentWorld: .page)
        }
    }

    private func disableMobileBrowserDirtyBeacon() {
        webView.configuration.userContentController.removeScriptMessageHandler(
            forName: MobileBrowserDirtyMessageHandler.name
        )
        mobileBrowserStreamMessageHandler = nil
        let activeWebView = webView
        Task { @MainActor [weak activeWebView] in
            try? await activeWebView?.evaluateJavaScript(
                "window.__cmuxMobileBrowserStreamBeacon && (window.__cmuxMobileBrowserStreamBeacon.enabled = false);",
                contentWorld: .page
            )
        }
    }
}
