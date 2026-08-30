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
        #expect(html.contains("pendingVolume = 100.0"))
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
        // YouTube rejects embeds whose document origin is null (error 153) or
        // youtube.com itself (error 152); the page must carry a third-party origin.
        #expect(VideoBackgroundEmbedPage.baseURL.scheme == "https")
        #expect(VideoBackgroundEmbedPage.baseURL.host == "cmux.com")
        #expect(html.contains("window.cmuxVideoBackgroundSetMuted = function"))
        #expect(VideoBackgroundEmbedPage.mutedScript(true) == "window.cmuxVideoBackgroundSetMuted(true);")
        #expect(VideoBackgroundEmbedPage.mutedScript(false) == "window.cmuxVideoBackgroundSetMuted(false);")
    }

    @Test func audioOptInStartsUnmutedButStillSilentByDefault() {
        let silent = VideoBackgroundEmbedPage(source: .youTubeVideo(id: "dQw4w9WgXcQ")).html
        #expect(silent.contains("mute: 1"))
        #expect(silent.contains("var pendingMuted = true;"))

        let audible = VideoBackgroundEmbedPage(source: .youTubeVideo(id: "dQw4w9WgXcQ"), muted: false).html
        #expect(audible.contains("mute: 0"))
        #expect(audible.contains("var pendingMuted = false;"))
        // Unmuting is applied on ready and on every resume, never before the player exists.
        #expect(audible.contains("applyMuted(event.target)"))
        #expect(!audible.contains("event.target.mute();"))
    }

    @Test func playerIsSizeCappedAndScaledToCoverTheWindow() {
        let html = VideoBackgroundEmbedPage(source: .youTubeVideo(id: "dQw4w9WgXcQ")).html
        #expect(html.contains("width: \(VideoBackgroundEmbedPage.playerWidth)px;"))
        #expect(html.contains("height: \(VideoBackgroundEmbedPage.playerHeight)px;"))
        #expect(html.contains("Math.max(window.innerWidth / playerWidth, window.innerHeight / playerHeight)"))
        #expect(html.contains("window.addEventListener('resize', fitPlayer)"))
        #expect(!html.contains("width: '100%'"))
    }

    @Test func qualityAndVolumeAreAppliedToTheEmbed() {
        let html = VideoBackgroundEmbedPage(
            source: .youTubeVideo(id: "dQw4w9WgXcQ"),
            queueManaged: true,
            quality: "4k",
            volume: 0.35
        ).html
        #expect(html.contains("width: 1920px"))
        #expect(html.contains("height: 1080px"))
        #expect(html.contains("loop: 0"))
        #expect(html.contains("pendingVolume = 35.0"))
        #expect(html.contains("event: 'ended'"))
        #expect(VideoBackgroundEmbedPage.volumeScript(0.35) == "window.cmuxVideoBackgroundSetVolume(35.0);")
    }
}
