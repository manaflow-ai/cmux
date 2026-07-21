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

    /// Applies the phone's point viewport through the shared automation reflow path.
    @discardableResult
    func applyMobileStreamViewport(width: Int, height: Int, scale: Double) -> Bool {
        let reportedViewport = MobileBrowserViewport(width: width, height: height, scale: scale)
        if mobileBrowserStreamViewportIsActive, mobileBrowserStreamViewport == reportedViewport {
            return true
        }
        guard let mapping = MobileBrowserStreamViewportMapping(
            width: width,
            height: height,
            scale: scale
        ) else {
            return false
        }

        let previousViewport = viewportModel.requestedViewport
        switch setAutomationViewport(mapping.viewport) {
        case .success:
            if !mobileBrowserStreamViewportIsActive {
                mobileBrowserStreamPreviousAutomationViewport = previousViewport
                mobileBrowserStreamViewportIsActive = true
            }
            mobileBrowserStreamViewport = reportedViewport
            forceMobileStreamRepaintAfterReflow()
            // `.reflowed` (not just `.dirty`) so the session schedules settle
            // re-captures: the relayout paints asynchronously and an idle page
            // sends no further dirty, so a single capture can grab a blank frame.
            publishMobileBrowserStreamSignal(.reflowed)
            return true
        case .failure:
            return false
        }
    }

    /// Forces a compositor repaint after a viewport reflow so the next capture
    /// is not a blank frame.
    ///
    /// An already-loaded, idle page reflowed to a new viewport relayouts but does
    /// not necessarily repaint on its own, so `takeSnapshot` right after the
    /// reflow can capture a WHITE frame that then sticks (the idle page sends no
    /// further dirty signal, so nothing re-captures). A user scroll recovers it,
    /// which is exactly the compositor nudge this reproduces programmatically: a
    /// double-`requestAnimationFrame` (runs after the relayout paints) followed
    /// by a net-zero 1px scroll jitter and a `resize` dispatch. Both fire the
    /// stream dirty beacon's listeners, so the settled, painted layout is
    /// captured and replaces the premature blank frame. The scroll is restored
    /// to its exact prior offset, so it is imperceptible; the `resize` dispatch
    /// covers short pages that have no scroll room to jitter.
    private func forceMobileStreamRepaintAfterReflow() {
        // Two REAL scrolls in SEPARATE frames, not a same-tick net-zero pair:
        // the browser coalesces `scrollTo(y+1); scrollTo(y)` in one tick to the
        // final position and never actually scrolls, so no repaint. Moving by a
        // real pixel in one frame and back in the next produces two genuine
        // scroll+repaint cycles (the compositor nudge a user scroll gives). A
        // page pinned at the top still has room to go down 1px; one pinned at the
        // bottom still has room to go up 1px, so at least one real move lands.
        let script = """
        (() => {
          const back = () => {
            try {
              window.scrollBy(0, -1);
              window.dispatchEvent(new Event('resize'));
            } catch (_) {}
          };
          const forward = () => {
            try { window.scrollBy(0, 1); } catch (_) {}
            try { requestAnimationFrame(back); } catch (_) { back(); }
          };
          try {
            requestAnimationFrame(() => requestAnimationFrame(forward));
          } catch (_) {
            forward();
          }
        })()
        """
        let activeWebView = webView
        Task { @MainActor [weak activeWebView] in
            try? await activeWebView?.evaluateJavaScript(script, contentWorld: .page)
        }
    }

    /// Restores the automation viewport that was active before phone streaming.
    func clearMobileStreamViewport() {
        guard mobileBrowserStreamViewportIsActive else { return }
        let previousViewport = mobileBrowserStreamPreviousAutomationViewport
        guard case .success = setAutomationViewport(previousViewport) else { return }
        mobileBrowserStreamViewportIsActive = false
        mobileBrowserStreamPreviousAutomationViewport = nil
        mobileBrowserStreamViewport = nil
        publishMobileBrowserStreamSignal(.dirty(editableFocused: nil))
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
        publishMobileBrowserStreamSignal(.webViewReplaced)
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
