import CmuxScreenKit
import Foundation
import Testing

struct ScreenKitTests {
    @Test func preferencesSavedByOlderBuildsStillLoad() throws {
        let old = try JSONDecoder().decode(ScreenPreferences.self, from: Data(#"{"localCursor":false}"#.utf8))
        #expect(old.localCursor == false)
        #expect(old.fitToDisplay, "fitted mode is the default")
        #expect(old.showStats)
        #expect(old.quality == .auto)
        #expect(old.showTrackpad, "the trackpad is up by default, also for preferences saved before it existed")
        #expect(old.maxKbps == nil, "no bitrate cap unless one was chosen")
        #expect(old.showCursorInStream, "the stream shows the cursor unless turned off")
        let unknownQuality = try JSONDecoder().decode(ScreenPreferences.self, from: Data(#"{"quality":"ultra"}"#.utf8))
        #expect(unknownQuality.quality == .auto)
    }

    @Test func preferencesRoundTrip() throws {
        let preferences = ScreenPreferences(localCursor: false, showStats: false, fitToDisplay: false, quality: .medium,
                                            showTrackpad: false, maxKbps: 5_000, showCursorInStream: false)
        let decoded = try JSONDecoder().decode(ScreenPreferences.self, from: JSONEncoder().encode(preferences))
        #expect(decoded == preferences)
        #expect(decoded.showTrackpad == false, "a tucked-away trackpad stays tucked away")
    }

    /// A closed session (its Mac forgotten, its tab closed) never connects again.
    @MainActor @Test func aClosedSessionNeverConnectsAgain() throws {
        let stream = try #require(VNCPairing(link: VNCPairing.generate(name: "Mac", kind: "stream").link))
        let session = ScreenSession(title: "Mac", pairing: stream)
        session.close()
        #expect(session.phase == .ended)
        session.connect()
        session.reconnect()
        session.resumeIfNeeded()
        #expect(session.phase == .ended && session.stream == nil && !session.isReconnecting)
    }

    /// Lawrence 2026-11-16 ("screen sharing is also black and not working"): a host's `status`
    /// message reaches the session, one it can't be viewed with fails the session with the host's
    /// sentence, and nothing after it (a drop, coming back to the foreground) brings back a black
    /// picture or replaces the reason. Retry (connect) clears it.
    @MainActor @Test func aHostThatCantShareKeepsItsReasonUntilRetry() throws {
        let sentence = "Lawrence's MacBook Pro can't share its screen yet: Screen Recording isn't allowed. On that Mac, open System Settings › Privacy & Security › Screen Recording and turn on cmux."
        let data = Data(#"{"t":"status","s":"\#(sentence)","state":"needs_screen_recording"}"#.utf8)
        let status = try #require(try JSONDecoder().decode(ScreenHostMessage.self, from: data).shareStatus)
        #expect(status == ScreenShareStatus(state: "needs_screen_recording", message: sentence))
        #expect(!status.canView && status.needsScreenRecording)

        let pairing = try #require(VNCPairing(link: VNCPairing.generate(name: "Mac", kind: "stream").link))
        let session = ScreenSession(title: "Lawrence's MacBook Pro", pairing: pairing)
        session.receiveShareStatus(status)
        #expect(session.cannotShare)
        #expect(session.shareStatus == status)
        #expect(session.phase == .failed(message: sentence, needsSignIn: false))
        #expect(session.stream == nil && !session.isReconnecting)
        // The host ends the session right after: the app coming back does not reconnect to black.
        session.resumeIfNeeded()
        #expect(session.phase == .failed(message: sentence, needsSignIn: false))
        #expect(session.shareStatus == status)
        session.close()
    }

    /// View only (`needs_accessibility`): the picture stays, with the host's sentence as a note.
    @MainActor @Test func aViewOnlyHostKeepsThePictureWithANote() throws {
        let pairing = try #require(VNCPairing(link: VNCPairing.generate(name: "Mac", kind: "stream").link))
        let session = ScreenSession(title: "Mac", pairing: pairing)
        let note = "Mac shares its screen view only: Accessibility isn't allowed."
        session.receiveShareStatus(ScreenShareStatus(state: "needs_accessibility", message: note))
        #expect(!session.cannotShare)
        #expect(session.viewOnlyNote == note)
        #expect(session.phase == .connecting, "nothing stopped")
        session.receiveShareStatus(ScreenShareStatus(state: "ready", message: ""))
        #expect(session.viewOnlyNote == nil)
        session.close()
    }

    /// A connected stream that decoded no frame for 2 s says so instead of showing black.
    @Test func noPictureAfterTwoSecondsWithNoFrame() {
        #expect(!ScreenSession.showsNoPicture(framesDecoded: 0, connectedFor: .milliseconds(1_999)))
        #expect(ScreenSession.showsNoPicture(framesDecoded: 0, connectedFor: .seconds(2)))
        #expect(!ScreenSession.showsNoPicture(framesDecoded: 1, connectedFor: .seconds(30)))
        #expect(ScreenSession.noPictureDelay == .seconds(2))
    }

    /// Reconnecting gives up after its tries or once it has tried for 45 s, whichever comes first.
    @Test func reconnectingGivesUpByTriesOrTime() {
        #expect(!ScreenSession.givesUp(attempts: 1, limit: 5, elapsed: 3))
        #expect(ScreenSession.givesUp(attempts: 5, limit: 5, elapsed: 3))
        #expect(ScreenSession.givesUp(attempts: 2, limit: 5, elapsed: 46))
        // A try never runs past the deadline: the last one gets only what is left.
        #expect(ScreenSession.attemptTimeout(elapsed: 0) == 30)
        #expect(ScreenSession.attemptTimeout(elapsed: 40) == 5)
        #expect(ScreenSession.attemptTimeout(elapsed: 44.5) == 1)
    }

    /// The Mac's locked / display-asleep state shows until it says live again (an older Mac never says: live).
    @MainActor @Test func theSourceStateFollowsTheMac() throws {
        let stream = try #require(VNCPairing(link: VNCPairing.generate(name: "Mac", kind: "stream").link))
        let session = ScreenSession(title: "Mac", pairing: stream)
        #expect(session.sourceState == .live)
        session.receiveSourceState(.locked)
        #expect(session.sourceState == .locked)
        session.receiveSourceState(.asleep)
        #expect(session.sourceState == .asleep)
        session.receiveSourceState(.live)
        #expect(session.sourceState == .live)
    }

    @MainActor @Test func sessionsKnowTheirKind() throws {
        let stream = try #require(VNCPairing(link: VNCPairing.generate(name: "Mac", kind: "stream").link))
        let rfb = try #require(VNCPairing(link: VNCPairing.generate(name: "Mac").link))
        #expect(ScreenSession(title: "Mac", pairing: stream).isStream)
        #expect(!ScreenSession(title: "Mac", pairing: rfb).isStream)
        let direct = ScreenSession(title: "Server", endpoint: VNCEndpoint(host: "192.168.1.2", port: 5900))
        #expect(!direct.isStream && !direct.isDemo)
        #expect(ScreenSession().isDemo)
        #expect(direct.phase == .connecting, "nothing runs until connect()")
        #expect(direct.id != ScreenSession().id)
    }

    @Test func orientationChoicesHaveTitlesAndSymbols() {
        #expect(OrientationLock.allCases.map(\.title) == ["Auto-Rotate", "Portrait", "Landscape"])
        #expect(OrientationLock.allCases.allSatisfy { !$0.symbol.isEmpty })
    }
}
