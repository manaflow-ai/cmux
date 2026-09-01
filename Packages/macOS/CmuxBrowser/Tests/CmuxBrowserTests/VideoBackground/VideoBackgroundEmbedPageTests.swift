import Foundation
import Testing
@testable import CmuxBrowser

@Suite("Video background embed page")
struct VideoBackgroundEmbedPageTests {
    @Test func videoPageLoopsTheSingleVideoMuted() {
        let html = VideoBackgroundEmbedPage(source: .youTubeVideo(id: "dQw4w9WgXcQ")).html
        #expect(html.contains("videoId: 'dQw4w9WgXcQ'"))
        #expect(html.contains("playlist: 'dQw4w9WgXcQ'"))
        #expect(html.contains("mute: 1"))
        #expect(html.contains("loop: 1"))
        #expect(html.contains("controls: 0"))
        #expect(html.contains("playsinline: 1"))
        #expect(html.contains("pointer-events: none"))
    }

    @Test func playlistPageUsesListTypePlaylist() {
        let html = VideoBackgroundEmbedPage(
            source: .youTubePlaylist(id: "PLBsP89CPrMeMJk4CM2TS7KAfQ57hGXbNe")
        ).html
        #expect(html.contains("listType: 'playlist'"))
        #expect(html.contains("list: 'PLBsP89CPrMeMJk4CM2TS7KAfQ57hGXbNe'"))
        #expect(!html.contains("videoId:"))
        #expect(html.contains("var isPlaylist = true;"))
    }

    @Test func pageWiresTheNativeBridge() {
        let html = VideoBackgroundEmbedPage(source: .youTubeVideo(id: "dQw4w9WgXcQ")).html
        #expect(html.contains("window.webkit.messageHandlers.\(VideoBackgroundEmbedPage.messageHandlerName).postMessage"))
        #expect(html.contains("window.cmuxVideoBackgroundSetPaused = function"))
        #expect(VideoBackgroundEmbedPage.pauseScript.contains("cmuxVideoBackgroundSetPaused(true)"))
        #expect(VideoBackgroundEmbedPage.resumeScript.contains("cmuxVideoBackgroundSetPaused(false)"))
        #expect(VideoBackgroundEmbedPage.baseURL.host == "www.youtube.com")
    }
}
