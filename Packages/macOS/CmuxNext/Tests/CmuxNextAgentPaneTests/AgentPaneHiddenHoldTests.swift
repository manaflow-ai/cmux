import Foundation
import Testing
@testable import CmuxNextAgentPane

/// A chat pane nobody can see gets no bridge call for a streaming turn: each call woke its page's
/// web process. Leo's running nightly (2026-10-21) had one hidden chat take 148 calls and 109
/// web-process sleep and wake cycles in two minutes, at the 0.25 s hidden interval.
@MainActor
struct AgentPaneHiddenHoldTests {
    typealias Rig = AgentPaneHiddenPacingTests.Rig

    @Test func aHiddenPaneStreamingATurnGetsNoCallUntilItShows() {
        let rig = Rig(hidden: true)
        // Two seconds of a streaming turn: frames every 62.5 ms, and any deadline the pacer sets.
        for _ in 0..<32 {
            rig.arrive()
            rig.clock += 0.0625
            rig.deadline.fire()
            rig.pacer.delivered()
        }
        #expect(rig.calls == 0, "a hidden pane's page was called \(rig.calls) times for a streaming turn")
        // Shown: the next frames go at once, with every frame held.
        rig.hidden = false
        rig.arrive()
        #expect(rig.calls == 1)
    }
}
