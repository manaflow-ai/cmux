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
            // The store drops presence for a surface it has not indexed yet,
            // so the hook runs only once the store knows the tab.
            // `tab(surface:)` is not tracked; `tabListRevision` wakes the wait
            // when the tab list changes.
            try await h.store.waitUntil("tab indexed") {
                _ = h.store.tabListRevision
                return h.store.tab(surface: surface) != nil
            }

            // The helper the installed hooks run, fed a Claude payload on stdin.
            // Returns what the terminal printed, so a `cmux-tui-hook:` error
            // shows up when the presence it should have set never arrives.
            func hook(_ event: String, _ payload: String, sentinel: String) async throws -> String {
                let output = try await h.run("printf '%s' '\(payload)' | '\(binary)' __agent-hook claude \(event); echo \(sentinel)-$((1+1))",
                                             in: surface, until: "\(sentinel)-2")
                if !output.contains("\(sentinel)-2") {
                    Issue.record("hook \(event) never finished; terminal output:\n\(output)")
                }
                return output
            }
            func wait(_ what: String, after output: String, _ condition: @escaping @MainActor () -> Bool) async throws {
                do {
                    try await h.store.waitUntil(what, condition)
                } catch {
                    Issue.record("\(what) never arrived; hook terminal output:\n\(output)")
                    throw error
                }
            }

            let readOutput = try await hook("PreToolUse", #"{"session_id":"presence-1","tool_name":"Read","tool_input":{"file_path":"/repo/src/lib.rs","offset":120}}"#,
                                            sentinel: "READ")
            try await wait("reading presence", after: readOutput) { h.store.tab(surface: surface)?.presence?.activity == .reading }
            let reading = try #require(await MainActor.run { h.store.tab(surface: surface)?.presence })
            #expect(reading.agent == "claude")
            #expect(reading.session == "presence-1")
            #expect(reading.tool == "Read")
            #expect(reading.path == "/repo/src/lib.rs")
            #expect(reading.line == 120)

            let stopOutput = try await hook("Stop", #"{"session_id":"presence-1"}"#, sentinel: "STOP")
            try await wait("presence cleared", after: stopOutput) { h.store.tab(surface: surface)?.presence == nil }
        }
    }
}
