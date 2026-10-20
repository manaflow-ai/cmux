import Darwin
import Foundation
import Testing
@testable import CmuxNextHomeEngine

/// The user, 2026-10-20: updates must never cut the Chief. An update that must hand the Chief's
/// acpmux off asks the Chief host to hand off when idle (SIGUSR1) instead of stopping it mid-turn,
/// but only a host that says it takes that signal (`state/host.handoff` names its pid): SIGUSR1
/// would end an older host at once.
struct ChiefHostIdleHandoffTests {
    private func home(lockPID: pid_t, handoffPID: pid_t?) throws -> ChiefHome {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("chief-idle-handoff-\(UUID().uuidString)")
        let state = root.appendingPathComponent("state", isDirectory: true)
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        try "\(lockPID)\n1\nflock\n".write(to: state.appendingPathComponent("host.lock"), atomically: true, encoding: .utf8)
        if let handoffPID {
            try "\(handoffPID)\n".write(to: state.appendingPathComponent("host.handoff"), atomically: true, encoding: .utf8)
        }
        return ChiefHome(root: root, isolated: false)
    }

    @Test func aHostThatTakesTheHandoffIsAskedToHandOffWhenIdle() throws {
        let home = try home(lockPID: 4242, handoffPID: 4242)
        var sent: [(pid_t, Int32)] = []
        let asked = ChiefHostStop.askToHandOffWhenIdle(home: home, isChiefHost: { _ in true }) { pid, signal in
            sent.append((pid, signal))
            return true
        }
        #expect(asked)
        #expect(sent.map(\.0) == [4242])
        #expect(sent.map(\.1) == [SIGUSR1])
    }

    @Test func anOlderHostIsNotSentTheSignal() throws {
        let home = try home(lockPID: 4242, handoffPID: nil)
        var sent: [(pid_t, Int32)] = []
        let asked = ChiefHostStop.askToHandOffWhenIdle(home: home, isChiefHost: { _ in true }) { pid, signal in
            sent.append((pid, signal))
            return true
        }
        #expect(!asked)
        #expect(sent.isEmpty)
    }

    @Test func aHandoffMarkOfAnEarlierHostDoesNotCount() throws {
        let home = try home(lockPID: 4242, handoffPID: 4141)
        var sent: [(pid_t, Int32)] = []
        let asked = ChiefHostStop.askToHandOffWhenIdle(home: home, isChiefHost: { _ in true }) { pid, signal in
            sent.append((pid, signal))
            return true
        }
        #expect(!asked)
        #expect(sent.isEmpty)
    }

    @Test func noRunningHostIsNotAsked() throws {
        let home = try home(lockPID: 4242, handoffPID: 4242)
        let asked = ChiefHostStop.askToHandOffWhenIdle(home: home, isChiefHost: { _ in false }) { _, _ in true }
        #expect(!asked)
    }
}
