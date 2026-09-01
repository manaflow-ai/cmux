import Foundation
import Testing
@testable import CmuxBrowser

@Suite("Video background source parsing")
struct VideoBackgroundSourceTests {
    @Test func parsesWatchURLs() {
        #expect(
            VideoBackgroundSource.parse("https://www.youtube.com/watch?v=dQw4w9WgXcQ")
                == .youTubeVideo(id: "dQw4w9WgXcQ")
        )
        #expect(
            VideoBackgroundSource.parse("https://m.youtube.com/watch?v=dQw4w9WgXcQ&t=42s")
                == .youTubeVideo(id: "dQw4w9WgXcQ")
        )
    }

    @Test func parsesShortLinkShortsEmbedAndLiveURLs() {
        #expect(VideoBackgroundSource.parse("https://youtu.be/dQw4w9WgXcQ") == .youTubeVideo(id: "dQw4w9WgXcQ"))
        #expect(
            VideoBackgroundSource.parse("https://www.youtube.com/shorts/dQw4w9WgXcQ")
                == .youTubeVideo(id: "dQw4w9WgXcQ")
        )
        #expect(
            VideoBackgroundSource.parse("https://www.youtube-nocookie.com/embed/dQw4w9WgXcQ")
                == .youTubeVideo(id: "dQw4w9WgXcQ")
        )
        #expect(
            VideoBackgroundSource.parse("https://www.youtube.com/live/dQw4w9WgXcQ")
                == .youTubeVideo(id: "dQw4w9WgXcQ")
        )
    }

    @Test func parsesPlaylistURLs() {
        #expect(
            VideoBackgroundSource.parse("https://www.youtube.com/playlist?list=PLBsP89CPrMeMJk4CM2TS7KAfQ57hGXbNe")
                == .youTubePlaylist(id: "PLBsP89CPrMeMJk4CM2TS7KAfQ57hGXbNe")
        )
    }

    @Test func playlistWinsOverVideoInWatchWithinPlaylistURLs() {
        #expect(
            VideoBackgroundSource.parse(
                "https://www.youtube.com/watch?v=dQw4w9WgXcQ&list=PLBsP89CPrMeMJk4CM2TS7KAfQ57hGXbNe"
            ) == .youTubePlaylist(id: "PLBsP89CPrMeMJk4CM2TS7KAfQ57hGXbNe")
        )
    }

    @Test func parsesRawIdentifiers() {
        #expect(VideoBackgroundSource.parse("dQw4w9WgXcQ") == .youTubeVideo(id: "dQw4w9WgXcQ"))
        #expect(
            VideoBackgroundSource.parse("PLBsP89CPrMeMJk4CM2TS7KAfQ57hGXbNe")
                == .youTubePlaylist(id: "PLBsP89CPrMeMJk4CM2TS7KAfQ57hGXbNe")
        )
        #expect(VideoBackgroundSource.parse("  dQw4w9WgXcQ  ") == .youTubeVideo(id: "dQw4w9WgXcQ"))
    }

    @Test func parsesLocalVideoFiles() {
        #expect(
            VideoBackgroundSource.parse("/tmp/loop.mp4")
                == .localFile(url: URL(fileURLWithPath: "/tmp/loop.mp4"))
        )
        #expect(
            VideoBackgroundSource.parse("file:///tmp/loop.mov")
                == .localFile(url: URL(string: "file:///tmp/loop.mov")!)
        )
        #expect(VideoBackgroundSource.parse("/tmp/notes.txt") == nil)
    }

    @Test func rejectsNonYouTubeAndMalformedInput() {
        #expect(VideoBackgroundSource.parse("") == nil)
        #expect(VideoBackgroundSource.parse("   ") == nil)
        #expect(VideoBackgroundSource.parse("https://vimeo.com/12345") == nil)
        #expect(VideoBackgroundSource.parse("https://www.youtube.com/") == nil)
        #expect(VideoBackgroundSource.parse("https://www.youtube.com/watch?v=short") == nil)
        #expect(VideoBackgroundSource.parse("not a url at all") == nil)
        #expect(VideoBackgroundSource.parse("https://www.youtube.com/watch?v=<script>bad") == nil)
    }

    @Test func identifierValidationEnforcesSafeCharset() {
        #expect(VideoBackgroundSource.isValidVideoID("dQw4w9WgXcQ"))
        #expect(!VideoBackgroundSource.isValidVideoID("dQw4w9WgXc'"))
        #expect(!VideoBackgroundSource.isValidVideoID("tooShort"))
        #expect(VideoBackgroundSource.isValidPlaylistID("PLBsP89CPrMeMJk4CM2TS7KAfQ57hGXbNe"))
        #expect(!VideoBackgroundSource.isValidPlaylistID("PL\"injection"))
    }
}
