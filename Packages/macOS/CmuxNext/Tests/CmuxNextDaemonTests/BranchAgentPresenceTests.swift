import Foundation
import Testing
@testable import CmuxNextDaemon

/// Agent presence end to end (`agent-presence-v1`, cx-gg84): a harness hook
/// run inside a terminal reaches the daemon through the real hook helper, and
/// the store's tab carries what the agent touches until its turn ends.
@Suite(.enabled(if: RealBinary.isBranchBuild, "needs the same-tree cmux-tui (scripts/cmux-next/pin-cmux-tui.sh fetch)"),
       .timeLimit(.minutes(2)), .liveDaemon)
struct BranchAgentPresenceTests {
    @Test func hookToolCallsReachTheTabAndTurnEndClearsThem() async throws {
        let binary = try #require(RealBinary.url).path
        try await BranchDaemonHarness.with { h in
            let (_, _, surface) = try await h.workspaceWithTerminal("presence")
            // The helper the installed hooks run, fed a Claude payload on stdin.
            func hook(_ event: String, _ payload: String, sentinel: String) async throws {
                _ = try await h.run("printf '%s' '\(payload)' | '\(binary)' __agent-hook claude \(event); echo \(sentinel)-$((1+1))",
                                    in: surface, until: "\(sentinel)-2")
            }

            try await hook("PreToolUse", #"{"session_id":"presence-1","tool_name":"Read","tool_input":{"file_path":"/repo/src/lib.rs","offset":120}}"#,
                           sentinel: "READ")
            try await h.store.waitUntil("reading presence") { h.store.tab(surface: surface)?.presence?.activity == .reading }
            let reading = try #require(await MainActor.run { h.store.tab(surface: surface)?.presence })
            #expect(reading.agent == "claude")
            #expect(reading.session == "presence-1")
            #expect(reading.tool == "Read")
            #expect(reading.path == "/repo/src/lib.rs")
            #expect(reading.line == 120)

            try await hook("Stop", #"{"session_id":"presence-1"}"#, sentinel: "STOP")
            try await h.store.waitUntil("presence cleared") { h.store.tab(surface: surface)?.presence == nil }
        }
    }
}
