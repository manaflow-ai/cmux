// SPDX-License-Identifier: GPL-3.0-or-later
import CmuxNextDaemon
import Foundation
@testable import CmuxNextMacScreen
import os
import Testing

/// What the app knows of the agents acting through Computer Use, from the daemon's
/// `computer-use-activity` (and a status read): the sessions, newest first, and `acting` (the menu
/// bar badge), which ends 2 s after the newest action through one wait on the injected clock.
@MainActor @Suite struct ComputerUseActivityStateTests {
    /// A clock the test moves; a wait ends when the test releases it.
    private final class Clock: Sendable {
        let now = OSAllocatedUnfairLock(initialState: Date(timeIntervalSince1970: 5_000))
        let waits = OSAllocatedUnfairLock(initialState: [Duration]())
        let release = AsyncStream<Void>.makeStream()

        func install(on state: CmuxRemoteComputerUseState) {
            state.now = { self.now.withLock { $0 } }
            state.sleep = { duration in
                self.waits.withLock { $0.append(duration) }
                for await _ in self.release.stream { return }
            }
        }

        func advance(_ seconds: TimeInterval) { now.withLock { $0 = $0.addingTimeInterval(seconds) } }
    }

    private func event(_ sessions: [[String: Any]]) throws -> JSONValue {
        let data = try JSONSerialization.data(withJSONObject: ["event": "computer-use-activity", "sessions": sessions])
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }

    @Test func anEventSaysWhoActsOnWhichAppNewestFirst() throws {
        let state = CmuxRemoteComputerUseState()
        let clock = Clock()
        clock.install(on: state)
        state.take(activityEvent: try event([
            ["session": "a", "label": "Codex", "last_action_ms": 4_990_000],
            ["session": "b", "label": "Claude Code", "app": ["id": "com.apple.Notes", "name": "Notes"], "last_action_ms": 4_999_500],
            ["label": "no session", "last_action_ms": 1],
        ]))
        #expect(state.sessions.map(\.id) == ["b", "a"])
        #expect(state.sessions[0] == CmuxRemoteComputerUseSession(id: "b", agent: "Claude Code", appID: "com.apple.Notes", appName: "Notes",
                                                                  lastAction: Date(timeIntervalSince1970: 4_999.5)))
        #expect(state.sessions[1].appName == nil)
        #expect(state.acting, "the newest acted half a second ago")
        state.take(activityEvent: try event([]))
        #expect(state.sessions.isEmpty && !state.acting)
    }

    /// The badge clears 2 s after the last action, by one wait for exactly what is left; a newer
    /// action replaces the wait. Nothing polls.
    @Test func actingEndsTwoSecondsAfterTheLastAction() async throws {
        let state = CmuxRemoteComputerUseState()
        let clock = Clock()
        clock.install(on: state)
        state.take(activityEvent: try event([["session": "a", "label": "Codex", "last_action_ms": 4_999_500]]))
        #expect(state.acting)
        let clear = try #require(state.actingClear)
        while clock.waits.withLock({ $0.isEmpty }) { await Task.yield() }
        #expect(clock.waits.withLock { $0 } == [.milliseconds(1500)])
        clock.advance(1.5)
        clock.release.continuation.yield()
        await clear.value
        #expect(!state.acting, "2 s after the last action")
        #expect(state.actingClear == nil)
        #expect(state.sessions.count == 1, "the session stays listed; it only stopped acting")
        // An old action never turns the badge on.
        state.take(activityEvent: try event([["session": "a", "label": "Codex", "last_action_ms": 4_000_000]]))
        #expect(!state.acting && state.actingClear == nil)
    }

    @Test func aStatusReadCarriesTheSameListAndNoHostClearsIt() {
        let state = CmuxRemoteComputerUseState()
        Clock().install(on: state)
        state.take(host: ["pid": 7, "workers": ["computer-use": ["state": "ready", "activity": [
            ["session": "a", "label": "Codex", "last_action_ms": 4_999_900],
        ]]]])
        #expect(state.sessions.map(\.id) == ["a"] && state.acting)
        state.take(host: ["pid": 7])
        #expect(state.sessions.map(\.id) == ["a"], "an answer without the worker's fields changes nothing")
        state.take(host: nil)
        #expect(state.sessions.isEmpty && !state.acting)
    }
}
