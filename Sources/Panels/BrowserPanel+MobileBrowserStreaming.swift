import CMUXMobileCore
import CmuxBrowser
import WebKit

@MainActor
extension BrowserPanel {
    static let mobileBrowserDirtyBeaconScript = """
    (() => {
      const handlerName = 'cmuxMobileBrowserStream';
      const editableFocused = () => {
        const el = document.activeElement;
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
        markDirty() {
          if (!this.enabled) return;
          this.pendingDirty = true;
          if (this.scheduled) return;
          this.scheduled = true;
          nativeRequestAnimationFrame(this.tick);
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
      for (const name of [
        'scroll', 'resize', 'input', 'focusin', 'focusout',
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

    func addMobileBrowserStreamSignalHandler(
        id handlerID: UUID,
        handler: @escaping (MobileBrowserPanelNativeSignal) -> Void
    ) {
        let wasInactive = mobileBrowserStreamSignalHandlers.isEmpty
        mobileBrowserStreamSignalHandlers[handlerID] = handler
        if wasInactive {
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
