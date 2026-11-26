@testable import CmuxNextHomeEngine
import CmuxNextHomeModel
import Testing

/// The `chief_brain` rules reach Swift through the FFI (cmux-home-rules chief_brain): one smoke
/// test per caller kind. The rule cases themselves are the Rust parity tests.
@Suite struct HomeRulesChiefBrainTests {
    @Test func stableCmuxStartsItsBundledChief() {
        #expect(HomeBrainHost.bundledChiefAllowed(bundleID: "com.cmuxterm.app", isDebugBuild: false))
        #expect(!HomeBrainHost.bundledChiefAllowed(bundleID: "com.example.other", isDebugBuild: false))
    }

    @Test func profileRelayRouteAnswers() throws {
        let reply = try HomeRules.callJSON(
            "chief_brain.profile_relay_route",
            #"{"operation":"chief.profile.undo","params":{"chief":"agent_chief"},"gestureEvent":1.5}"#)
        #expect(reply.contains(#""known":true"#))
        #expect(reply.contains(#""gesture":true"#))
    }
}
