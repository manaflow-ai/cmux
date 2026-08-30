public import Foundation

/// Generates the self-contained HTML page hosting the YouTube IFrame player
/// for the dynamic video background.
///
/// The page is loaded into a non-interactive `WKWebView` with
/// ``VideoBackgroundEmbedPage/baseURL`` as its document origin (YouTube
/// refuses to play inside a null-origin document or one that claims to be
/// youtube.com itself). The player is chrome-free
/// and looping, silent unless the host opts in to audio; the native side
/// drives pause/resume and mute through ``VideoBackgroundEmbedPage/pauseScript``,
/// ``resumeScript`` and ``mutedScript(_:)`` and hears about fatal player
/// errors through the ``VideoBackgroundEmbedPage/messageHandlerName`` script
/// message handler.
///
/// Performance guardrail: the player element is kept at a quality-dependent
/// logical size and scaled up with a GPU transform to cover the window.
/// YouTube picks the stream resolution from the element's pixel size, so the
/// default 1080p cap avoids fetching a 4K stream for a large window while
/// allowing users to opt into a sharper stream.
public struct VideoBackgroundEmbedPage: Sendable {
    /// The source rendered by this page. Only YouTube sources are supported;
    /// local files play through AVFoundation instead.
    public let source: VideoBackgroundSource

    /// Whether the player starts silent. Audio can be toggled live via
    /// ``mutedScript(_:)``.
    public let muted: Bool

    /// Whether native queue advancement owns end-of-item events.
    public let queueManaged: Bool

    /// Maximum YouTube quality requested for this page.
    public let quality: String

    /// Volume applied when the page is unmuted (`0...1`).
    public let volume: Double

    /// Logical player size before the cover-scale transform (16:9).
    public static let playerWidth = 960
    public static let playerHeight = 540

    /// Returns the logical 16:9 player size for a quality label.
    public static func dimensions(for quality: String) -> (width: Int, height: Int) {
        switch quality.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "720", "720p": return (640, 360)
        case "1440", "1440p", "2k": return (1280, 720)
        case "2160", "2160p", "4k", "uhd": return (1920, 1080)
        default: return (Self.playerWidth, Self.playerHeight)
        }
    }

    /// Document base URL giving the page a real origin YouTube will serve.
    ///
    /// The IFrame player validates the embedding document's origin/referrer:
    /// a null origin (`about:blank`) fails with error 153 and a document
    /// claiming to *be* `youtube.com` fails with error 152, while an ordinary
    /// third-party origin plays. cmux's own domain is the honest choice.
    public static let baseURL = URL(string: "https://cmux.com/video-background")!

    /// The host that actually serves the player; used to pick a browser
    /// identity (user agent) YouTube treats as a full Safari.
    public static let playerHostURL = URL(string: "https://www.youtube.com")!

    /// Name of the `WKScriptMessageHandler` the page posts events to.
    public static let messageHandlerName = "cmuxVideoBackground"

    /// JavaScript expression that pauses playback (safe before player init).
    public static let pauseScript = "window.cmuxVideoBackgroundSetPaused(true);"

    /// JavaScript expression that resumes playback (safe before player init).
    public static let resumeScript = "window.cmuxVideoBackgroundSetPaused(false);"

    /// JavaScript expression that mutes or unmutes playback (safe before player init).
    public static func mutedScript(_ muted: Bool) -> String {
        "window.cmuxVideoBackgroundSetMuted(\(muted ? "true" : "false"));"
    }

    /// JavaScript expression that sets YouTube volume (`0...100`).
    public static func volumeScript(_ volume: Double) -> String {
        let clamped = volume.isFinite ? min(max(volume, 0), 1) : 1
        return String(
            format: "window.cmuxVideoBackgroundSetVolume(%.1f);",
            locale: Locale(identifier: "en_US_POSIX"),
            clamped * 100
        )
    }

    /// JavaScript expression that seeks the player to a shared playhead.
    public static func positionScript(_ seconds: TimeInterval) -> String {
        let clamped = seconds.isFinite ? max(0, seconds) : 0
        return String(
            format: "window.cmuxVideoBackgroundSetPosition(%.3f);",
            locale: Locale(identifier: "en_US_POSIX"),
            clamped
        )
    }

    /// Creates a page for a parsed YouTube source.
    ///
    /// - Parameters:
    ///   - source: A ``VideoBackgroundSource/youTubeVideo(id:)`` or
    ///     ``VideoBackgroundSource/youTubePlaylist(id:)`` value. A local-file
    ///     source produces an empty player that reports an error.
    ///   - muted: Whether playback starts silent. Defaults to `true`.
    ///   - queueManaged: Whether native queue advancement owns end events.
    ///     Defaults to `false` for backwards-compatible single-source looping.
    ///   - quality: Maximum YouTube quality. Defaults to `1080p`.
    ///   - volume: Initial volume from `0...1`. Defaults to `1`.
    public init(
        source: VideoBackgroundSource,
        muted: Bool = true,
        queueManaged: Bool = false,
        quality: String = "1080p",
        volume: Double = 1
    ) {
        self.source = source
        self.muted = muted
        self.queueManaged = queueManaged
        self.quality = quality
        self.volume = volume.isFinite ? min(max(volume, 0), 1) : 1
    }

    /// The full HTML document for the player page.
    public var html: String {
        let dimensions = Self.dimensions(for: quality)
        let playerConfiguration: String
        switch source {
        case let .youTubeVideo(id):
            // `loop` only takes effect when `playlist` repeats the video ID.
            playerConfiguration = """
            videoId: '\(id)',
            playerVars: { ...sharedPlayerVars, playlist: '\(id)' }
            """
        case let .youTubePlaylist(id):
            playerConfiguration = """
            playerVars: { ...sharedPlayerVars, listType: 'playlist', list: '\(id)' }
            """
        case .localFile:
            playerConfiguration = "playerVars: { ...sharedPlayerVars }"
        }

        return """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <style>
          html, body {
            margin: 0;
            padding: 0;
            width: 100%;
            height: 100%;
            overflow: hidden;
            background: transparent;
            pointer-events: none;
          }
          /* Fixed logical size (caps the stream resolution YouTube selects);
             fitPlayer() scales it to cover the window, cropping instead of
             letterboxing. */
          #player {
            position: absolute;
            top: 50%;
            left: 50%;
            width: \(dimensions.width)px;
            height: \(dimensions.height)px;
            transform: translate(-50%, -50%);
            transform-origin: center center;
            pointer-events: none;
            border: 0;
          }
        </style>
        </head>
        <body>
        <div id="player"></div>
        <script>
          'use strict';
          var player = null;
          var pendingPaused = false;
          var pendingMuted = \(muted ? "true" : "false");
          var pendingVolume = \(self.volume * 100);
          var pendingPosition = 0;
          var playerWidth = \(dimensions.width);
          var playerHeight = \(dimensions.height);

          function fitPlayer() {
            var element = document.getElementById('player');
            if (!element) { return; }
            var scale = Math.max(window.innerWidth / playerWidth, window.innerHeight / playerHeight);
            element.style.transform = 'translate(-50%, -50%) scale(' + scale + ')';
          }
          window.addEventListener('resize', fitPlayer);

          function applyMuted(target) {
            if (!target || typeof target.mute !== 'function') { return; }
            if (pendingMuted) { target.mute(); } else { target.unMute(); }
          }

          function postToHost(payload) {
            try {
              window.webkit.messageHandlers.\(Self.messageHandlerName).postMessage(payload);
            } catch (error) {}
          }

          window.cmuxVideoBackgroundSetPaused = function (paused) {
            pendingPaused = !!paused;
            if (!player || typeof player.pauseVideo !== 'function') { return; }
            if (pendingPaused) {
              player.pauseVideo();
            } else {
              applyMuted(player);
              player.playVideo();
            }
          };

          window.cmuxVideoBackgroundSetMuted = function (muted) {
            pendingMuted = !!muted;
            applyMuted(player);
          };

          window.cmuxVideoBackgroundSetVolume = function (volume) {
            var next = Number(volume);
            if (!isFinite(next)) { next = 100; }
            pendingVolume = Math.max(0, Math.min(100, next));
            if (player && typeof player.setVolume === 'function') {
              player.setVolume(pendingVolume);
            }
          };

          window.cmuxVideoBackgroundSetPosition = function (seconds) {
            var next = Number(seconds);
            if (!isFinite(next) || next < 0) { next = 0; }
            pendingPosition = next;
            if (player && typeof player.seekTo === 'function' && next > 0) {
              player.seekTo(next, true);
            }
          };

          var sharedPlayerVars = {
            autoplay: 1,
            controls: 0,
            disablekb: 1,
            fs: 0,
            iv_load_policy: 3,
            rel: 0,
            playsinline: 1,
            mute: \(muted ? 1 : 0),
            loop: \(queueManaged ? 0 : 1)
          };

          function onYouTubeIframeAPIReady() {
            player = new YT.Player('player', {
              width: playerWidth,
              height: playerHeight,
              \(playerConfiguration),
              events: {
                onReady: function (event) {
                  fitPlayer();
                  applyMuted(event.target);
                  if (typeof event.target.setVolume === 'function') {
                    event.target.setVolume(pendingVolume);
                  }
                  if (pendingPosition > 0 && typeof event.target.seekTo === 'function') {
                    event.target.seekTo(pendingPosition, true);
                  }
                  if (!pendingPaused) { event.target.playVideo(); }
                  postToHost({ event: 'ready' });
                },
                onStateChange: function (event) {
                  if (event.data === YT.PlayerState.ENDED && !pendingPaused) {
                    if (\(queueManaged ? "true" : "false")) {
                      postToHost({ event: 'ended' });
                    } else {
                      // `loop` handles wrap-around; this covers edge cases
                      // where the player lands in ENDED anyway.
                      event.target.playVideo();
                    }
                  }
                },
                onError: function (event) {
                  var isPlaylist = \(isPlaylistLiteral);
                  if (isPlaylist && player && typeof player.nextVideo === 'function') {
                    // Skip playlist entries that refuse embedding.
                    player.nextVideo();
                    postToHost({ event: 'skipped', code: event.data });
                  } else {
                    postToHost({ event: 'error', code: event.data });
                  }
                }
              }
            });
          }

          fitPlayer();
          var apiScript = document.createElement('script');
          apiScript.src = 'https://www.youtube.com/iframe_api';
          apiScript.onerror = function () { postToHost({ event: 'error', code: 'api-load-failed' }); };
          document.body.appendChild(apiScript);
        </script>
        </body>
        </html>
        """
    }

    private var isPlaylistLiteral: String {
        if case .youTubePlaylist = source { return "true" }
        return "false"
    }
}
