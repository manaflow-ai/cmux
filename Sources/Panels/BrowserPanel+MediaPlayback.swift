import CmuxBrowser
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
    /// actively-playing and audible `<video>`/`<audio>` elements, and whether one
    /// of its videos is in Picture in Picture.
    ///
    /// Runs in every frame (main frame and cross-origin iframes) so an embedded
    /// player (a news site embedding a YouTube/Vimeo/Twitch iframe, etc.) keeps
    /// its hidden pane alive too. Each frame tags its report with a stable
    /// per-document id; the native side keeps a pane alive while any frame is
    /// playing and releases it once every frame has stopped
    /// (https://github.com/manaflow-ai/cmux/issues/5409).
    ///
    /// Reports only on change (debounced via `lastReported`) and on `pagehide`.
    /// The broad `playing` state uses `paused`/`ended`, so muted playback still
    /// keeps a hidden pane alive. The narrower `audible` state additionally
    /// requires an unmuted element with non-zero volume and a detectable audio
    /// source, so the speaker glyph is not shown for muted or video-only media.
    /// A paused Picture in Picture window still keeps the pane alive: the page
    /// owns the floating window, so discarding it would close the window.
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

        let lastReported = { playing: null, audible: null, pip: null };
        let lastElementState = new WeakMap();
        let mediaObserver = null;

        const isElementPlaying = (el) => {
          try {
            return !!el && !el.paused && !el.ended;
          } catch (_) {
            return false;
          }
        };

        const hasAudioSource = (el) => {
          try {
            const tagName = (el.tagName || "").toLowerCase();
            if (tagName === "audio") return true;
            const tracks = el.audioTracks;
            if (tracks && typeof tracks.length === "number") {
              let sawEnabledState = false;
              for (let i = 0; i < tracks.length; i++) {
                const track = tracks[i];
                if (!track || typeof track.enabled !== "boolean") continue;
                sawEnabledState = true;
                if (track.enabled) return true;
              }
              if (sawEnabledState) return false;
            }
            if (typeof el.webkitAudioDecodedByteCount === "number" && el.webkitAudioDecodedByteCount > 0) {
              return true;
            }
          } catch (_) {}
          return false;
        };

        const isElementAudible = (el) => {
          try {
            return isElementPlaying(el)
              && !el.muted
              && el.volume > 0
              && hasAudioSource(el);
          } catch (_) {
            return false;
          }
        };

        const isElementInPictureInPicture = (el) => {
          try {
            return document.pictureInPictureElement === el
              || el.webkitPresentationMode === "picture-in-picture";
          } catch (_) {
            return false;
          }
        };

        const isPictureInPictureActive = () => {
          try {
            if (document.pictureInPictureElement) return true;
            const videos = document.querySelectorAll("video");
            for (let i = 0; i < videos.length; i++) {
              if (isElementInPictureInPicture(videos[i])) return true;
            }
          } catch (_) {}
          return false;
        };

        const currentPlaybackState = () => {
          const state = { playing: false, audible: false, pip: isPictureInPictureActive() };
          try {
            const media = document.querySelectorAll("video, audio");
            for (let i = 0; i < media.length; i++) {
              const el = media[i];
              if (!isElementPlaying(el)) continue;
              state.playing = true;
              if (isElementAudible(el)) {
                state.audible = true;
                break;
              }
            }
          } catch (_) {}
          return state;
        };

        const post = (playing, audible, pip) => {
          try {
            window.webkit.messageHandlers["\(mediaPlaybackMessageHandlerName)"].postMessage({
              frameID: frameID,
              playing: playing,
              audible: audible,
              pip: pip
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
          const state = currentPlaybackState();
          syncObserver(state.playing || state.pip);
          if (state.playing === lastReported.playing
            && state.audible === lastReported.audible
            && state.pip === lastReported.pip) return;
          lastReported = state;
          post(state.playing, state.audible, state.pip);
        }

        function reportIfTargetStateChanged(event) {
          try {
            const el = event && event.target;
            if (!el || !el.matches || !el.matches("video, audio")) {
              report();
              return;
            }
            const next = {
              playing: isElementPlaying(el),
              audible: isElementAudible(el),
              pip: isElementInPictureInPicture(el)
            };
            const previous = lastElementState.get(el);
            if (previous
              && previous.playing === next.playing
              && previous.audible === next.audible
              && previous.pip === next.pip) return;
            lastElementState.set(el, next);
            report();
          } catch (_) {
            report();
          }
        }

        // Media events do not bubble, but capture-phase listeners on `document`
        // still observe them as the event travels down to the target element.
        const events = [
          "play", "playing", "pause", "ended", "emptied",
          "waiting", "stalled", "suspend", "abort", "loadeddata",
          "volumechange", "timeupdate", "enterpictureinpicture",
          "leavepictureinpicture", "webkitpresentationmodechanged"
        ];
        for (let i = 0; i < events.length; i++) {
          document.addEventListener(events[i], reportIfTargetStateChanged, true);
        }

        window.addEventListener("pagehide", () => {
          disconnectObserver();
          if (lastReported.playing === false
            && lastReported.audible === false
            && lastReported.pip === false) return;
          lastReported = { playing: false, audible: false, pip: false };
          post(false, false, false);
        }, true);

        document.addEventListener("DOMContentLoaded", report, true);
        report();
      } catch (_) {}
      return true;
    })();
    """

    /// Reports `<video>`/`<audio>` playback so a hidden pane with actively-playing
    /// media is exempted from memory discard
    /// (https://github.com/manaflow-ai/cmux/issues/5409). Injected into every
    /// frame so embedded players in cross-origin iframes keep the pane alive
    /// too. Runs in an isolated content world (shared DOM, separate JS scope)
    /// so the handler is hidden from page JavaScript that could otherwise post
    /// a fake playing report; this also keeps it clear of CAPTCHA fingerprint
    /// checks in those iframes.
    static func installMediaPlaybackUserScript(into configuration: WKWebViewConfiguration) {
        configuration.userContentController.addUserScript(
            WKUserScript(
                source: mediaPlaybackTrackingBootstrapScriptSource,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: false,
                in: mediaPlaybackContentWorld
            )
        )
    }

    /// Installs the media-playback message handler on `webView`.
    ///
    /// Each `BrowserPanel` webview is created with a fresh `WKWebViewConfiguration`
    /// (`makeWebView`), so the handler name is never registered twice on one
    /// content controller. Reset media tracking for the freshly bound webview.
    func setupMediaPlaybackMessageHandler(for webView: WKWebView) {
        resetMediaPlaybackTracking()
        // Bind the handler to this webview generation. The handler stays alive on
        // the old content controller until the old webview deallocates, so a late
        // report from a replaced document must be ignored or it would repopulate
        // mediaPlaybackFrames for a page that is gone and block discard forever.
        let boundWebViewInstanceID = webViewInstanceID
        let handler = BrowserMediaPlaybackMessageHandler(webView: webView) { [weak self] report in
            self?.handleMediaPlaybackReport(report, fromWebViewInstanceID: boundWebViewInstanceID)
        }
        mediaPlaybackMessageHandler = handler
        webView.configuration.userContentController.add(
            handler,
            contentWorld: Self.mediaPlaybackContentWorld,
            name: mediaPlaybackMessageHandlerName
        )
    }

    func tearDownMediaPlaybackMessageHandler(for webView: WKWebView) {
        webView.configuration.userContentController.removeScriptMessageHandler(
            forName: mediaPlaybackMessageHandlerName,
            contentWorld: Self.mediaPlaybackContentWorld
        )
        mediaPlaybackMessageHandler = nil
        resetMediaPlaybackTracking()
    }

    /// Applies a per-frame playback report from the injected hook, aggregating
    /// across the main frame and any iframes. Reports from a superseded webview
    /// generation are dropped.
    func handleMediaPlaybackReport(
        _ report: BrowserMediaPlaybackReport,
        fromWebViewInstanceID instanceID: UUID
    ) {
        guard instanceID == webViewInstanceID else { return }
        applyMediaPlaybackReport(report)
#if DEBUG
        cmuxDebugLog(
            "browser.media.playback panel=\(id.uuidString.prefix(5)) " +
            "frame=\(report.frameID.prefix(5)) playing=\(report.isPlaying ? 1 : 0) " +
            "audible=\(report.isAudible ? 1 : 0) pip=\(report.isPictureInPicture ? 1 : 0) " +
            "anyPlaying=\(isPlayingMedia ? 1 : 0) " +
            "anyAudible=\(isPlayingAudio ? 1 : 0)"
        )
#endif
    }
}
