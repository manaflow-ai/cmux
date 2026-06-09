import Foundation
import WebKit

/// Name of the `WKScriptMessageHandler` the injected media-playback hook posts to.
private let mediaPlaybackMessageHandlerName = "cmuxMediaPlayback"

extension BrowserPanel {
    /// Isolated content world for the media-playback hook.
    ///
    /// Both the injected script and the message handler live here, not the page
    /// world, so arbitrary page JavaScript cannot reach
    /// the private media-playback message handler and post a fake `{ playing:
    /// true }` report that would pin the pane alive forever and defeat
    /// hidden-webview discard. A content world shares the DOM, so the script's
    /// media event listeners and `MutationObserver` still observe page playback.
    static let mediaPlaybackContentWorld = WKContentWorld.world(name: mediaPlaybackMessageHandlerName)

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
        let mediaObserver = null;

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
            window.webkit.messageHandlers["\(mediaPlaybackMessageHandlerName)"].postMessage({
              frameID: frameID,
              playing: playing
            });
          } catch (_) {}
        };

        const disconnectObserver = () => {
          if (!mediaObserver) return;
          try { mediaObserver.disconnect(); } catch (_) {}
          mediaObserver = null;
        };

        const removedMedia = (node) => {
          try {
            if (!node || node.nodeType !== 1) return false;
            if (node.matches && node.matches("video, audio")) return true;
            return !!(node.querySelector && node.querySelector("video, audio"));
          } catch (_) {
            return false;
          }
        };

        // Removing a playing element from the DOM fires no media event, so while
        // anything is playing watch for DOM mutations and recheck. This is the
        // only signal that survives while the page is hidden (timers are
        // throttled, MutationObserver is not), so a player that tears down its
        // <video> still clears the blocker and lets the pane be discarded.
        //
        // Only recheck when a mutation actually removes a media element; added
        // media already fires a `play` event. This avoids a full-document
        // querySelectorAll on every DOM change of a mutation-heavy SPA (live
        // chat, infinite scroll) while a video plays.
        function syncObserver(playing) {
          if (playing) {
            if (mediaObserver) return;
            try {
              mediaObserver = new MutationObserver((records) => {
                for (let i = 0; i < records.length; i++) {
                  const removed = records[i].removedNodes;
                  for (let j = 0; j < removed.length; j++) {
                    if (removedMedia(removed[j])) {
                      report();
                      return;
                    }
                  }
                }
              });
              mediaObserver.observe(document.documentElement || document, {
                childList: true,
                subtree: true
              });
            } catch (_) {}
          } else {
            disconnectObserver();
          }
        }

        function report() {
          const playing = anyPlaying();
          syncObserver(playing);
          if (playing === lastReported) return;
          lastReported = playing;
          post(playing);
        }

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
          disconnectObserver();
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
        // Bind the handler to this webview generation. The handler stays alive on
        // the old content controller until the old webview deallocates, so a late
        // report from a replaced document must be ignored or it would repopulate
        // playingMediaFrameIDs for a page that is gone and block discard forever.
        let boundWebViewInstanceID = webViewInstanceID
        let handler = BrowserMediaPlaybackMessageHandler { [weak self] report in
            self?.handleMediaPlaybackReport(report, fromWebViewInstanceID: boundWebViewInstanceID)
        }
        mediaPlaybackMessageHandler = handler
        webView.configuration.userContentController.add(
            handler,
            contentWorld: Self.mediaPlaybackContentWorld,
            name: mediaPlaybackMessageHandlerName
        )
    }

    /// Applies a per-frame playback report from the injected hook, aggregating
    /// across the main frame and any iframes. Reports from a superseded webview
    /// generation are dropped.
    func handleMediaPlaybackReport(
        _ report: BrowserMediaPlaybackReport,
        fromWebViewInstanceID instanceID: UUID
    ) {
        guard instanceID == webViewInstanceID else { return }
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
