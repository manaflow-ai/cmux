import Foundation
import WebKit

// MARK: - Bridge contract

/// Name of the `WKScriptMessageHandler` the injected media-playback hook posts to.
private let mediaPlaybackMessageHandlerName = "cmuxMediaPlayback"

/// Receives `{ playing: Bool }` from the injected media-playback hook and forwards
/// it to the owning ``BrowserPanel`` on the main actor.
///
/// Mirrors ``ReactGrabMessageHandler``: a thin `NSObject` adapter so the panel
/// itself never has to conform to `WKScriptMessageHandler`.
final class BrowserMediaPlaybackMessageHandler: NSObject, WKScriptMessageHandler {
    private let onPlayingChanged: @MainActor (Bool) -> Void

    init(onPlayingChanged: @escaping @MainActor (Bool) -> Void) {
        self.onPlayingChanged = onPlayingChanged
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard let body = message.body as? [String: Any],
              let playing = body["playing"] as? Bool else { return }
        Task { @MainActor in
            onPlayingChanged(playing)
        }
    }
}

// MARK: - BrowserPanel extension

extension BrowserPanel {
    /// Injected document-start hook that reports whether the main frame currently
    /// has any actively-playing `<video>`/`<audio>` element.
    ///
    /// Reports only on change (debounced via `lastReported`) and on `pagehide`,
    /// so a backgrounded YouTube tab keeps its hidden pane alive while audio is
    /// playing and releases it the moment playback stops
    /// (https://github.com/manaflow-ai/cmux/issues/5409). Uses only public DOM
    /// APIs, so it is stable across WebKit/macOS versions, unlike the private
    /// `_isPlayingAudio` KVO property.
    static let mediaPlaybackTrackingBootstrapScriptSource = """
    (() => {
      try {
        if (window.__cmuxMediaPlaybackTrackerInstalled) return true;
        window.__cmuxMediaPlaybackTrackerInstalled = true;

        let lastReported = null;

        const isElementPlaying = (el) => {
          try {
            return !!el && !el.paused && !el.ended;
          } catch (_) {
            return false;
          }
        };

        const anyPlaying = () => {
          try {
            const media = document.querySelectorAll("video, audio");
            for (let i = 0; i < media.length; i++) {
              if (isElementPlaying(media[i])) return true;
            }
          } catch (_) {}
          return false;
        };

        const post = (playing) => {
          try {
            window.webkit.messageHandlers.cmuxMediaPlayback.postMessage({ playing: playing });
          } catch (_) {}
        };

        const report = () => {
          const playing = anyPlaying();
          if (playing === lastReported) return;
          lastReported = playing;
          post(playing);
        };

        // Media events do not bubble, but capture-phase listeners on `document`
        // still observe them as the event travels down to the target element.
        const events = [
          "play", "playing", "pause", "ended", "emptied",
          "waiting", "stalled", "suspend", "abort", "loadeddata"
        ];
        for (let i = 0; i < events.length; i++) {
          document.addEventListener(events[i], report, true);
        }

        window.addEventListener("pagehide", () => {
          lastReported = false;
          post(false);
        }, true);

        document.addEventListener("DOMContentLoaded", report, true);
        report();
      } catch (_) {}
      return true;
    })();
    """

    /// Installs the media-playback message handler on `webView`.
    ///
    /// Each `BrowserPanel` webview is created with a fresh `WKWebViewConfiguration`
    /// (`makeWebView`), so the handler name is never registered twice on one
    /// content controller. Reset `isPlayingMedia` for the freshly bound webview.
    func setupMediaPlaybackMessageHandler(for webView: WKWebView) {
        let handler = BrowserMediaPlaybackMessageHandler { [weak self] playing in
            self?.handleMediaPlaybackChange(isPlaying: playing)
        }
        mediaPlaybackMessageHandler = handler
        webView.configuration.userContentController.add(handler, name: mediaPlaybackMessageHandlerName)
    }

    /// Applies a playback-state report from the injected hook.
    func handleMediaPlaybackChange(isPlaying: Bool) {
        setIsPlayingMedia(isPlaying)
#if DEBUG
        cmuxDebugLog(
            "browser.media.playback panel=\(id.uuidString.prefix(5)) playing=\(isPlaying ? 1 : 0)"
        )
#endif
    }
}
