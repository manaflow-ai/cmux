import CmuxNextDaemon
import Foundation
import Testing
@testable import CmuxNextBridge

/// A view whose stream ended or whose attach failed is disconnected, never
/// closed: it re-attaches on the next event that can make an attach work
/// (shown again, a key press, a click or focus, the terminal or the
/// connection back). Coordinator decision after dogfood nxdog11.
struct TerminalReattachTests {
    typealias Machine = TerminalAttachMachine<Int>

    static let initial = CellSize(cols: 80, rows: 24)
    static let wide = CellSize(cols: 120, rows: 40)

    private func live(link: Int = 7) -> Machine {
        var machine = Machine(initialSize: Self.initial, visible: true)
        _ = machine.reduce(.start)
        _ = machine.reduce(.resize(Self.wide))
        _ = machine.reduce(.opened(link, attempt: 1))
        _ = machine.reduce(.replayDelivered(link))
        return machine
    }

    private func opens(_ effects: [Machine.Effect]) -> Bool {
        effects.contains { if case .open = $0 { true } else { false } }
    }

    @Test func aDetachedStreamDisconnectsInsteadOfClosing() {
        var machine = live()
        let effects = machine.reduce(.ended(7, .surfaceGone))
        #expect(effects.contains(.detach(7)))
        #expect(!effects.contains(.finish), "the view's stream must stay open for a re-attach")
        #expect(!machine.isClosed)
    }

    @Test func showingADisconnectedViewReattaches() {
        var machine = live()
        _ = machine.reduce(.ended(7, .surfaceGone))
        _ = machine.reduce(.visibility(false))
        #expect(opens(machine.reduce(.visibility(true))))
    }

    @Test func focusOnADisconnectedViewReattaches() {
        var machine = live()
        _ = machine.reduce(.ended(7, .connectionLost("gone")))
        #expect(opens(machine.reduce(.focused)))
    }

    @Test func typingInADisconnectedViewReattachesAndSendsTheKeysAfterTheReplay() {
        var machine = live()
        _ = machine.reduce(.ended(7, .surfaceGone))
        let effects = machine.reduce(.input(Data("ls\r".utf8)))
        guard case .open(let attempt, _)? = effects.first(where: { if case .open = $0 { true } else { false } }) else {
            Issue.record("typing did not re-attach: \(effects)")
            return
        }
        #expect(machine.droppedInputBytes == 0)
        _ = machine.reduce(.opened(8, attempt: attempt))
        #expect(machine.reduce(.replayDelivered(8)).contains(.send(8, Data("ls\r".utf8))))
    }

    @Test func aFailedAttachDisconnectsAndTheNextFocusTriesAgain() {
        var machine = Machine(initialSize: Self.initial)
        _ = machine.reduce(.start)
        #expect(!machine.reduce(.openFailed(attempt: 1)).contains(.finish))
        #expect(!machine.isClosed)
        #expect(opens(machine.reduce(.focused)))
    }

    @Test func oneReattachAtATime() {
        var machine = live()
        _ = machine.reduce(.ended(7, .surfaceGone))
        #expect(opens(machine.reduce(.focused)))
        #expect(!opens(machine.reduce(.focused)))
        #expect(!opens(machine.reduce(.input(Data("x".utf8)))))
    }
}
