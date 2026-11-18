@testable import CmuxNextMacScreen
import CmuxScreenKit
import Foundation
import Testing

/// The Mac reads `cmux rd share-status` (the Rust contract) as it is printed, and an answer it
/// cannot read is no answer (the session then serves as before), never a made-up state.
@Suite struct MacScreenShareStatusProbeTests {
    @Test func readsTheProbesJSONLine() {
        let line = #"{"state":"needs_screen_recording","message":"Mini can't share its screen yet: Screen Recording isn't allowed.","settings":"x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture","can_view":false,"can_control":false}"#
        let status = MacScreenShareStatusProbe.decode(Data((line + "\n").utf8))
        #expect(status == ScreenShareStatus(state: "needs_screen_recording",
                                            message: "Mini can't share its screen yet: Screen Recording isn't allowed."))
    }

    @Test func unreadableOutputIsNoAnswer() {
        #expect(MacScreenShareStatusProbe.decode(Data()) == nil)
        #expect(MacScreenShareStatusProbe.decode(Data("cmux-rd: unknown command share-status\n".utf8)) == nil)
    }

    @Test func aMissingBinaryIsNoAnswer() async {
        let probe = MacScreenShareStatusProbe(host: "Mini", grantee: "cmux", binary: { nil })
        #expect(await probe.read(scope: "view", frame: false) == nil)
    }

    @Test func aProbeThatFailsOrHangsIsNoAnswer() async {
        let fails = MacScreenShareStatusProbe(host: "Mini", grantee: "cmux", binary: { URL(fileURLWithPath: "/usr/bin/false") })
        #expect(await fails.read(scope: "view", frame: false) == nil)
        // `yes` never exits: the deadline ends it.
        let hangs = MacScreenShareStatusProbe(host: "Mini", grantee: "cmux", deadline: .milliseconds(200),
                                              binary: { URL(fileURLWithPath: "/usr/bin/yes") })
        #expect(await hangs.read(scope: "view", frame: false) == nil)
    }
}
