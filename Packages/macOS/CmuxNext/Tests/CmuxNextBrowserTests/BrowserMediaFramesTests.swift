@testable import CmuxNextBrowser
import Foundation
import Testing

/// Every frame of a page reports media on its own (`BrowserMediaState+Scripts`), and the tab keeps
/// one report per frame (`BrowserMediaFrames`, in `BrowserTabStateMachine`). Before, one slot took
/// every frame's report: an ad iframe that stopped and reported null erased the main frame's paused
/// video, whose card (and Play button) came back only with that frame's next media event once the
/// observer's idle 3 s re-send was gone.
@Suite struct BrowserMediaFramesTests {
    static let paused = BrowserMediaState(title: "Talk", isPlaying: false, isVideo: true, position: 30, duration: 600)
    static let ad = BrowserMediaState(title: "Ad", isPlaying: true, isVideo: true, position: 1, duration: 15)

    @Test func anotherFramesNullKeepsThisFramesPausedReport() {
        var machine = BrowserTabStateMachine()
        machine.apply(.mediaChanged(Self.paused, frame: "main"))
        machine.apply(.mediaChanged(Self.ad, frame: "ad"))
        #expect(machine.state.media?.title == "Ad", "what plays shows over what is paused")
        machine.apply(.mediaChanged(nil, frame: "ad"))
        #expect(machine.state.media?.title == "Talk", "the ad's null erased the main frame's paused video")
        machine.apply(.mediaChanged(nil, frame: "main"))
        #expect(machine.state.media == nil)
    }

    @Test func theFrameThatStartedPlayingLastShowsAndAHeartbeatDoesNotFlip() {
        var frames = BrowserMediaFrames()
        _ = frames.apply(BrowserMediaState(title: "A", isPlaying: true), from: "a")
        _ = frames.apply(BrowserMediaState(title: "B", isPlaying: true), from: "b")
        #expect(frames.current?.title == "B")
        // A's heartbeat (same state, later position) does not take the card back.
        #expect(frames.apply(BrowserMediaState(title: "A", isPlaying: true, position: 3), from: "a")?.title == "B")
        #expect(frames.apply(BrowserMediaState(title: "B", isPlaying: false), from: "b")?.title == "A")
        #expect(frames.apply(BrowserMediaState(title: "B", isPlaying: true, isPictureInPicture: true), from: "b")?.title == "B")
    }

    /// Issue 38062: a frame's Web Audio (a report with no element) must not take the tab's media
    /// from another frame's video, playing or paused; it lends the shown report its speaker.
    @Test func soundWithNoElementNeverHidesAnotherFramesVideo() {
        let sound = BrowserMediaState(title: "Game", isPlaying: true, isSoundOnly: true, isOtherSound: true)
        var frames = BrowserMediaFrames()
        _ = frames.apply(BrowserMediaState(title: "Talk", isPlaying: true, isVideo: true), from: "main")
        #expect(frames.apply(sound, from: "ad")?.title == "Talk", "a later Web Audio frame took the playing video's place")
        let shown = frames.apply(Self.paused, from: "main")
        #expect(shown?.title == "Talk", "a Web Audio frame took the paused video's place")
        #expect(shown?.isSounding == true && shown?.isOtherSound == true, "the other frame's sound lost the speaker")
        #expect(frames.apply(nil, from: "main") == sound, "alone, the sound shows")
        #expect(frames.apply(nil, from: "ad") == nil)
    }

    @Test func aNewDocumentDropsEveryFramesReport() {
        var machine = BrowserTabStateMachine()
        let id = BrowserNavigationID(rawValue: 1)
        machine.apply(.started(id, url: URL(string: "https://example.com/")))
        machine.apply(.committed(id, url: URL(string: "https://example.com/")))
        machine.apply(.mediaChanged(Self.paused, frame: "main"))
        machine.apply(.mediaChanged(Self.ad, frame: "ad"))
        let next = BrowserNavigationID(rawValue: 2)
        machine.apply(.started(next, url: URL(string: "https://example.org/")))
        machine.apply(.committed(next, url: URL(string: "https://example.org/")))
        #expect(machine.state.media == nil)
        machine.apply(.mediaChanged(nil, frame: "new"))
        #expect(machine.state.media == nil, "a frame of the old document came back")
    }
}
