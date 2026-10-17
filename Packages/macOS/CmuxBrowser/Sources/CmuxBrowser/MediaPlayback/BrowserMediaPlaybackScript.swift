import Foundation

/// The document-start media-playback hook both engines inject into every frame
/// of a page, in an isolated world, to drive the tab's speaker glyph and the
/// hidden-pane discard exemption.
public enum BrowserMediaPlaybackScript {
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
    /// iframes. The engine injects it once per document, so no install guard is
    /// needed. Known limitation: media produced via the Web Audio API with no
    /// `<video>`/`<audio>` element (some web games) is not detected, since a
    /// running `AudioContext` is not a reliable "audible" signal and would
    /// over-retain idle panes.
    ///
    /// A report is the object `report` (`{ frameID, playing, audible, pip }`).
    /// While `ready` is false a report is held and retried, so Chromium's
    /// binding, which arrives after the document's world exists, still gets
    /// the first playing report; a frame that never played posts nothing then.
    /// - Parameters:
    ///   - post: A JavaScript statement that sends `report`.
    ///   - ready: A JavaScript expression, true once `post` can send.
    /// - Returns: The script source.
    public static func source(post: String, ready: String = "true") -> String {
        #"""
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
            let posted = false;
            let retryTimer = 0;
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

            // Returns false while the channel is not ready yet (Chromium adds its
            // binding once the document's isolated world exists).
            const post = (playing, audible, pip) => {
              const report = { frameID: frameID, playing: playing, audible: audible, pip: pip };
              if (!(\#(ready))) return false;
              try {
                \#(post);
              } catch (_) {}
              return true;
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
              if (!post(state.playing, state.audible, state.pip)) {
                // A frame that never reported has nothing to clear: quiet is
                // the native side's default for it.
                if (!posted && !state.playing && !state.audible && !state.pip) {
                  lastReported = state;
                  return;
                }
                retryReportLater();
                return;
              }
              posted = true;
              lastReported = state;
            }

            function retryReportLater() {
              if (retryTimer) return;
              retryTimer = setTimeout(() => {
                retryTimer = 0;
                report();
              }, 250);
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
        """#
    }
}
