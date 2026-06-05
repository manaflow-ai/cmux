import Foundation
import WebKit

// MARK: - Bridge contract

/// Name of the `WKScriptMessageHandler` the injected media-playback hook posts to.
private let mediaPlaybackMessageHandlerName = "cmuxMediaPlayback"

/// A per-frame media-playback report from the injected hook.
struct BrowserMediaPlaybackReport {
    /// Stable id for the reporting frame's document, so the native side can
    /// aggregate playback across the main frame and any (cross-origin) iframes.
    let frameID: String
    /// Whether that frame currently has any actively-playing media.
    let isPlaying: Bool
}

/// Receives `{ frameID, playing }` from the injected media-playback hook and
/// forwards it to the owning ``BrowserPanel`` on the main actor.
///
/// Mirrors ``ReactGrabMessageHandler``: a thin `NSObject` adapter so the panel
/// itself never has to conform to `WKScriptMessageHandler`.
final class BrowserMediaPlaybackMessageHandler: NSObject, WKScriptMessageHandler {
    private let onReport: @MainActor (BrowserMediaPlaybackReport) -> Void

    init(onReport: @escaping @MainActor (BrowserMediaPlaybackReport) -> Void) {
        self.onReport = onReport
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard let body = message.body as? [String: Any],
              let frameID = body["frameID"] as? String,
              let playing = body["playing"] as? Bool else { return }
        let report = BrowserMediaPlaybackReport(frameID: frameID, isPlaying: playing)
        Task { @MainActor in
            onReport(report)
        }
    }
}

// MARK: - BrowserPanel extension

extension BrowserPanel {
    /// Injected document-start hook that reports whether the current frame has
    /// any actively-playing `<video>`/`<audio>` element.
    ///
    /// Runs in every frame (main frame and cross-origin iframes) so an embedded
    /// player (a news site embedding a YouTube/Vimeo/Twitch iframe, etc.) keeps
    /// its hidden pane alive too. Each frame tags its report with a stable
    /// per-document id; the native side keeps a pane alive while any frame is
    /// playing and releases it once every frame has stopped
    /// (https://github.com/manaflow-ai/cmux/issues/5409).
    ///
    /// Reports only on change (debounced via `lastReported`) and on `pagehide`.
    /// Uses `paused`/`ended`, so playback that the user has muted still counts as
    /// "playing media" (matching Chrome's keep-alive). Uses only public DOM APIs,
    /// so it is stable across WebKit/macOS versions, unlike the private
    /// `_isPlayingAudio` KVO property (which would also drop user-muted video).
    ///
    /// The script is purely passive (capture-phase listeners only; no console,
    /// prototype, or enumerable-global tampering) so it does not trip the
    /// fingerprinting checks of CAPTCHA providers that live in cross-origin
    /// iframes. `WKUserScript` injects it once per document, so no install guard
    /// is needed. Known limitation: media produced via the Web Audio API with no
    /// `<video>`/`<audio>` element (some web games) is not detected, since a
    /// running `AudioContext` is not a reliable "audible" signal and would
    /// over-retain idle panes.
    static let mediaPlaybackTrackingBootstrapScriptSource = """
    (() => {
      try {
        const frameID = (() => {
          try {
            if (window.crypto && typeof window.crypto.randomUUID === "function") {
              return window.crypto.randomUUID();
            }
          } catch (_) {}
          return Date.now().toString(36) + "-" + Math.random().toString(36).slice(2);
        })();

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
            window.webkit.messageHandlers.cmuxMediaPlayback.postMessage({
              frameID: frameID,
              playing: playing
            });
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
          if (lastReported === false) return;
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
        resetMediaPlaybackTracking()
        let handler = BrowserMediaPlaybackMessageHandler { [weak self] report in
            self?.handleMediaPlaybackReport(report)
        }
        mediaPlaybackMessageHandler = handler
        webView.configuration.userContentController.add(handler, name: mediaPlaybackMessageHandlerName)
    }

    /// Applies a per-frame playback report from the injected hook, aggregating
    /// across the main frame and any iframes.
    func handleMediaPlaybackReport(_ report: BrowserMediaPlaybackReport) {
        applyMediaPlaybackReport(frameID: report.frameID, isPlaying: report.isPlaying)
#if DEBUG
        cmuxDebugLog(
            "browser.media.playback panel=\(id.uuidString.prefix(5)) " +
            "frame=\(report.frameID.prefix(5)) playing=\(report.isPlaying ? 1 : 0) " +
            "anyPlaying=\(isPlayingMedia ? 1 : 0)"
        )
#endif
    }
}
