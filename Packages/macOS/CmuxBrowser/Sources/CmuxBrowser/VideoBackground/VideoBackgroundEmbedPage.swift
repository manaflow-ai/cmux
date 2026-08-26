public import Foundation

/// Generates the self-contained HTML page hosting the YouTube IFrame player
/// for the dynamic video background.
///
/// The page is loaded into a non-interactive `WKWebView` with
/// ``VideoBackgroundEmbedPage/baseURL`` as its document origin (YouTube
/// refuses to play inside a null-origin document). The player is always
/// muted, chrome-free, and looping; the native side drives pause/resume
/// through ``VideoBackgroundEmbedPage/pauseScript``/``resumeScript`` and
/// hears about fatal player errors through the
/// ``VideoBackgroundEmbedPage/messageHandlerName`` script message handler.
public struct VideoBackgroundEmbedPage: Sendable {
    /// The source rendered by this page. Only YouTube sources are supported;
    /// local files play through AVFoundation instead.
    public let source: VideoBackgroundSource

    /// Document base URL giving the page a real origin YouTube will serve.
    public static let baseURL = URL(string: "https://www.youtube.com")!

    /// Name of the `WKScriptMessageHandler` the page posts events to.
    public static let messageHandlerName = "cmuxVideoBackground"

    /// JavaScript expression that pauses playback (safe before player init).
    public static let pauseScript = "window.cmuxVideoBackgroundSetPaused(true);"

    /// JavaScript expression that resumes playback (safe before player init).
    public static let resumeScript = "window.cmuxVideoBackgroundSetPaused(false);"

    /// Creates a page for a parsed YouTube source.
    ///
    /// - Parameter source: A ``VideoBackgroundSource/youTubeVideo(id:)`` or
    ///   ``VideoBackgroundSource/youTubePlaylist(id:)`` value. A local-file
    ///   source produces an empty player that reports an error.
    public init(source: VideoBackgroundSource) {
        self.source = source
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
          /* Cover the window with a 16:9 player, cropping instead of letterboxing. */
          #player {
            position: absolute;
            top: 50%;
            left: 50%;
            width: max(100vw, 177.78vh);
            height: max(100vh, 56.25vw);
            transform: translate(-50%, -50%);
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
              player.mute();
              player.playVideo();
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
            mute: 1,
            loop: 1
          };

          function onYouTubeIframeAPIReady() {
            player = new YT.Player('player', {
              width: '100%',
              height: '100%',
              \(playerConfiguration),
              events: {
                onReady: function (event) {
                  event.target.mute();
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
