import Darwin
import Foundation
import Testing
@testable import CmuxNextAgentPane
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
        #expect(asked == 4242)
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
        #expect(asked == nil)
        #expect(sent.isEmpty)
    }

    @Test func aHandoffMarkOfAnEarlierHostDoesNotCount() throws {
        let home = try home(lockPID: 4242, handoffPID: 4141)
        var sent: [(pid_t, Int32)] = []
        let asked = ChiefHostStop.askToHandOffWhenIdle(home: home, isChiefHost: { _ in true }) { pid, signal in
            sent.append((pid, signal))
            return true
        }
        #expect(asked == nil)
        #expect(sent.isEmpty)
    }

    @Test func noRunningHostIsNotAsked() throws {
        let home = try home(lockPID: 4242, handoffPID: 4242)
        let asked = ChiefHostStop.askToHandOffWhenIdle(home: home, isChiefHost: { _ in false }) { _, _ in true }
        #expect(asked == nil)
    }

    // 15:41 and 16:57 PT, 2026-10-20: a Chief chat the peer check refused healed by stopping the
    // Chief host at once (ChiefAcpmuxHeal), so its running turn was cut ("the acpmux connection
    // was lost during the turn"). The heal must wait for the turn like a relaunch does.
    @Test func theHealWaitsForAHostThatHandsOffWhenIdle() async {
        let action = await AcpmuxChiefHandoff.replacedAction(replaced: true, agentHosts: true, hostWaits: { true })
        #expect(action == .waitForHost)
    }

    @Test func theHealHandsOffAtOnceWhenTheHostCannotWait() async {
        let action = await AcpmuxChiefHandoff.replacedAction(replaced: true, agentHosts: true, hostWaits: { false })
        #expect(action == .handOff)
    }

    @Test func theHealNeverAsksTheHostWhenNothingIsStale() async {
        var asked = false
        let action = await AcpmuxChiefHandoff.replacedAction(replaced: false, agentHosts: true, hostWaits: { asked = true; return true })
        #expect(action == .keep)
        #expect(!asked)
        let noHosts = await AcpmuxChiefHandoff.replacedAction(replaced: true, agentHosts: false, hostWaits: { asked = true; return true })
        #expect(noHosts == .keep)
        #expect(!asked)
    }
}

/// Review of #22767: a heal that waited for the Chief host's turn left the handoff to
/// `HomeBrainHost.start`, which hands off once per Chief home per app run and runs only when the
/// brain watch restarts the host. The heal now finishes the handoff itself after the host exits.
struct ChiefHealAfterTurnTests {
    actor Calls {
        var names: [String] = []
        func add(_ name: String) { names.append(name) }
    }

    @Test func afterTheTurnTheHealHandsOffStopsAndStartsTheHost() async {
        let calls = Calls()
        await ChiefAcpmuxHeal.finishAfterTurn(
            hostExited: { await calls.add("exit"); return true },
            handOff: { await calls.add("handOff"); return true },
            stopHost: { await calls.add("stop") },
            ensureHost: { await calls.add("ensure") })
        #expect(await calls.names == ["exit", "handOff", "stop", "ensure"])
    }

    @Test func aDaemonAlreadyHandedOffStillGetsAHost() async {
        let calls = Calls()
        await ChiefAcpmuxHeal.finishAfterTurn(
            hostExited: { true },
            handOff: { await calls.add("handOff"); return false },
            stopHost: { await calls.add("stop") },
            ensureHost: { await calls.add("ensure") })
        #expect(await calls.names == ["handOff", "ensure"])
    }

    @Test func aHostThatNeverEndsItsTurnIsLeftAlone() async {
        let calls = Calls()
        await ChiefAcpmuxHeal.finishAfterTurn(
            hostExited: { false },
            handOff: { await calls.add("handOff"); return true },
            stopHost: { await calls.add("stop") },
            ensureHost: { await calls.add("ensure") })
        #expect(await calls.names.isEmpty)
    }
}
