import CmuxNextDaemon
import Foundation
import Testing
@testable import CmuxNextBridge

/// T7 (plans/cmux-next/remote-state-ownership.md S3): keys typed into a pane Cmd+D shows before
/// the daemon created its terminal wait in the view's attach machine while the attach waits for
/// the terminal (`TerminalTargetGate`), and reach the terminal once, in order, after its first
/// replay; nothing is sent to it before the replay.
struct ProvisionalTypeaheadTests {
    typealias Machine = TerminalAttachMachine<Int>

    @Test func keysTypedBeforeTheTerminalExistsArriveInOrderAfterTheReplay() {
        var machine = Machine(initialSize: CellSize(cols: 80, rows: 24), visible: true)
        var effects = machine.reduce(.start)
        var attempt = 0
        for effect in effects { if case .open(let a, _) = effect { attempt = a } }
        #expect(attempt != 0, "the view starts its attach at once (it then waits for the gate)")
        for key in ["l", "s", " ", "-", "l", "a", "\r"] {
            effects = machine.reduce(.input(Data(key.utf8)))
            #expect(!effects.contains { if case .send = $0 { true } else { false } }, "nothing is sent before the replay")
        }
        #expect(machine.droppedInputBytes == 0)
        _ = machine.reduce(.opened(7, attempt: attempt))
        let sent = machine.reduce(.replayDelivered(7)).compactMap { effect -> Data? in
            if case .send(7, let data) = effect { return data }
            return nil
        }
        #expect(String(decoding: sent.reduce(Data(), +), as: UTF8.self) == "ls -la\r")
    }
}
