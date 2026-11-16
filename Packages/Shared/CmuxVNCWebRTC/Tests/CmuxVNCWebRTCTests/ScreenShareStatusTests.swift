@testable import CmuxVNCWebRTC
import Foundation
import Testing

/// A host that cannot capture tells the viewer why (a `status` message), so the viewer shows the
/// reason instead of a black picture (Lawrence via Leo, 2026-11-16: "screen sharing is also black
/// and not working").
struct ScreenShareStatusTests {
    @Test func statusMessageRoundTripsTheStateAndSentence() throws {
        let sentence = "Lawrence's MacBook Pro can't share its screen yet: Screen Recording isn't allowed."
        let data = try JSONEncoder().encode(ScreenHostMessage.status(state: "needs_screen_recording", message: sentence))
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["t"] as? String == "status")
        #expect(object["state"] as? String == "needs_screen_recording")
        #expect(object["s"] as? String == sentence)
        let decoded = try JSONDecoder().decode(ScreenHostMessage.self, from: data)
        let status = try #require(decoded.shareStatus)
        #expect(status == ScreenShareStatus(state: "needs_screen_recording", message: sentence))
        #expect(!status.canView)
        #expect(status.needsScreenRecording)
    }

    @Test func onlyStatusMessagesCarryAStatus() throws {
        let caps = try JSONDecoder().decode(ScreenHostMessage.self, from: Data(#"{"t":"caps","s":"scroll-px"}"#.utf8))
        #expect(caps.shareStatus == nil)
        // A status with no state (a malformed host) is no status.
        let bare = try JSONDecoder().decode(ScreenHostMessage.self, from: Data(#"{"t":"status","s":"x"}"#.utf8))
        #expect(bare.shareStatus == nil)
        #expect(!ScreenStreamViewer.isDisplays(bare), "a status is never read as displays")
    }

    @Test func viewOnlyAndReadyStatesStillShowTheScreen() {
        #expect(ScreenShareStatus(state: "ready", message: "").canView)
        #expect(ScreenShareStatus(state: "needs_accessibility", message: "x").canView)
        #expect(!ScreenShareStatus(state: "capture_failed", message: "x").canView)
    }
}
