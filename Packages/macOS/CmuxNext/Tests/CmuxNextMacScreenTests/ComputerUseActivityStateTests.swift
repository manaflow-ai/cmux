// SPDX-License-Identifier: GPL-3.0-or-later
import CmuxNextComputerUse
import CmuxNextDaemon
import CmuxNextWakeupsTestSupport
import Foundation
@testable import CmuxNextMacScreen
import os
import Testing

/// What the app knows of the agents acting through Computer Use, from the daemon's
/// `computer-use-activity` (and a status read): the sessions, newest first, and `acting` (the menu
/// bar badge), which ends 2 s after the newest action through one deadline on the injected clock.
@MainActor @Suite(.timeLimit(.minutes(1))) struct ComputerUseActivityStateTests {
    /// The wall clock the worker's stamps are compared with; the test moves it.
    private final class Wall: Sendable {
        let now = OSAllocatedUnfairLock(initialState: Date(timeIntervalSince1970: 5_000))
        func advance(_ seconds: TimeInterval) { now.withLock { $0 = $0.addingTimeInterval(seconds) } }
    }

    private func state(_ clock: ManualClock = ManualClock(), wall: Wall = Wall()) -> CmuxRemoteComputerUseState {
        let state = CmuxRemoteComputerUseState(clock: clock)
        state.now = { wall.now.withLock { $0 } }
        return state
    }

    private func event(_ sessions: [[String: Any]]) throws -> JSONValue {
        let data = try JSONSerialization.data(withJSONObject: ["event": "computer-use-activity", "sessions": sessions])
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }

    @Test func anEventSaysWhoActsOnWhichAppNewestFirst() throws {
        let state = state()
        state.take(activityEvent: try event([
            ["session": "a", "label": "Codex", "last_action_ms": 4_990_000],
            ["session": "b", "label": "Claude Code", "app": ["id": "com.apple.Notes", "name": "Notes", "pid": 77],
             "last_action_ms": 4_999_500],
            ["label": "no session", "last_action_ms": 1],
        ]))
        #expect(state.sessions.map(\.id) == ["b", "a"])
        #expect(state.sessions[0] == CmuxRemoteComputerUseSession(id: "b", agent: "Claude Code", appID: "com.apple.Notes", appName: "Notes",
                                                                  appPID: 77, lastAction: Date(timeIntervalSince1970: 4_999.5)))
        #expect(state.sessions[1].appName == nil && state.sessions[1].live.target == nil)
        #expect(state.sessions[0].live.target == ComputerUseLiveSession.Target(pid: 77, bundleID: "com.apple.Notes", appName: "Notes"))
        #expect(state.acting, "the newest acted half a second ago")
        let rows = state.menuBarSessions(now: Date(timeIntervalSince1970: 5_000))
        #expect(rows.map(\.acting) == [true, false])
        #expect(rows[0].agent == "Claude Code" && rows[0].bundleID == "com.apple.Notes")
        state.take(activityEvent: try event([]))
        #expect(state.sessions.isEmpty && !state.acting)
        #expect(!state.actingClear.isScheduled)
    }

    /// The badge clears 2 s after the last action, by one deadline for what is left of the window;
    /// a newer action replaces it. Nothing polls.
    @Test func actingEndsTwoSecondsAfterTheLastAction() async throws {
        let clock = ManualClock(), wall = Wall()
        let state = state(clock, wall: wall)
        state.take(activityEvent: try event([["session": "a", "label": "Codex", "last_action_ms": 4_999_500]]))
        #expect(state.acting && state.actingClear.isScheduled)
        try await clock.waitForSleeper()
        wall.advance(1.4)
        clock.advance(by: .milliseconds(1400))
        await Task.yield()
        #expect(state.acting, "still within the window")
        wall.advance(0.1)
        clock.advance(by: .milliseconds(100))
        for _ in 0..<10_000 where state.acting { await Task.yield() }
        #expect(!state.acting, "2 s after the last action")
        #expect(state.sessions.count == 1, "the session stays listed; it only stopped acting")
        // An old action never turns the badge on.
        state.take(activityEvent: try event([["session": "a", "label": "Codex", "last_action_ms": 4_000_000]]))
        #expect(!state.acting && !state.actingClear.isScheduled)
    }

    @Test func aStatusReadCarriesTheSameListAndNoHostClearsIt() {
        let state = state()
        state.take(host: ["pid": 7, "workers": ["computer-use": ["state": "ready", "activity": [
            ["session": "a", "label": "Codex", "last_action_ms": 4_999_900],
        ]]]])
        #expect(state.sessions.map(\.id) == ["a"] && state.acting)
        state.take(host: ["pid": 7])
        #expect(state.sessions.map(\.id) == ["a"], "an answer without the worker's fields changes nothing")
        state.take(host: nil)
        #expect(state.sessions.isEmpty && !state.acting)
    }

    /// A session the person stopped: listed as stopped, never acting (no badge), until it resumes.
    @Test func aStoppedSessionIsListedButNeverActs() throws {
        let state = state()
        state.take(activityEvent: try event([["session": "a", "label": "Codex", "last_action_ms": 4_999_900, "stopped": true]]))
        #expect(state.sessions.first?.stopped == true)
        #expect(!state.acting && !state.actingClear.isScheduled, "a stopped agent shows no badge")
        let row = state.menuBarSessions(now: Date(timeIntervalSince1970: 5_000))[0]
        #expect(row.stopped && !row.acting)
        // The app's own Resume marks it at once; the worker's next event agrees.
        state.mark("a", stopped: false)
        #expect(state.sessions.first?.stopped == false && state.acting)
        state.mark("a", stopped: true)
        #expect(!state.acting)
        state.mark("missing", stopped: false)
        #expect(state.sessions.count == 1)
    }
}
