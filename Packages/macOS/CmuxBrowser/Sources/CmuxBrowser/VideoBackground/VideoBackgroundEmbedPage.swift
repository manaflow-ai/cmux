public import Foundation

/// Generates the self-contained HTML page hosting the YouTube IFrame player
/// for the dynamic video background.
///
/// The page is loaded into a non-interactive `WKWebView` with
/// ``VideoBackgroundEmbedPage/baseURL`` as its document origin (YouTube
/// refuses to play inside a null-origin document). The player is chrome-free
/// and looping, silent unless the host opts in to audio; the native side
/// drives pause/resume and mute through ``VideoBackgroundEmbedPage/pauseScript``,
/// ``resumeScript`` and ``mutedScript(_:)`` and hears about fatal player
/// errors through the ``VideoBackgroundEmbedPage/messageHandlerName`` script
/// message handler.
///
/// Performance guardrail: the player element is kept at
/// ``playerWidth``×``playerHeight`` CSS pixels and scaled up with a GPU
/// transform to cover the window. YouTube picks the stream resolution from the
/// element's pixel size, so this caps decoding at roughly 1080p on Retina
/// displays instead of fetching a 4K stream for a large window.
public struct VideoBackgroundEmbedPage: Sendable {
    /// The source rendered by this page. Only YouTube sources are supported;
    /// local files play through AVFoundation instead.
    public let source: VideoBackgroundSource

    /// Whether the player starts silent. Audio can be toggled live via
    /// ``mutedScript(_:)``.
    public let muted: Bool

    /// Logical player size before the cover-scale transform (16:9).
    public static let playerWidth = 960
    public static let playerHeight = 540

    /// Document base URL giving the page a real origin YouTube will serve.
    public static let baseURL = URL(string: "https://www.youtube.com")!

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

    /// Creates a page for a parsed YouTube source.
    ///
    /// - Parameters:
    ///   - source: A ``VideoBackgroundSource/youTubeVideo(id:)`` or
    ///     ``VideoBackgroundSource/youTubePlaylist(id:)`` value. A local-file
    ///     source produces an empty player that reports an error.
    ///   - muted: Whether playback starts silent. Defaults to `true`.
    public init(source: VideoBackgroundSource, muted: Bool = true) {
        self.source = source
        self.muted = muted
    }

    /// The full HTML document for the player page.
    public var html: String {
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
            width: \(Self.playerWidth)px;
            height: \(Self.playerHeight)px;
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
          var playerWidth = \(Self.playerWidth);
          var playerHeight = \(Self.playerHeight);

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

          var sharedPlayerVars = {
            autoplay: 1,
            controls: 0,
            disablekb: 1,
            fs: 0,
            iv_load_policy: 3,
            rel: 0,
            playsinline: 1,
            mute: \(muted ? 1 : 0),
            loop: 1
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
                  if (!pendingPaused) { event.target.playVideo(); }
                  postToHost({ event: 'ready' });
                },
                onStateChange: function (event) {
                  // `loop` handles wrap-around; this covers edge cases where
                  // the player lands in ENDED anyway.
                  if (event.data === YT.PlayerState.ENDED && !pendingPaused) {
                    event.target.playVideo();
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
