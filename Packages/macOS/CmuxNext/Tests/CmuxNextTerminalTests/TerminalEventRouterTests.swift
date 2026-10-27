import CmuxNextCompat
@testable import CmuxNextTerminal
@testable import CmuxNextWakeups
import Dispatch
import Foundation
import GhosttyNextKit
import Testing

/// A session's events loop never waits for the main actor (p03-rendering-085): output and grid locks
/// reach the output lane in stream order, at the lane's own generation, while the main actor is held,
/// and the grid, status and chip the main actor shows coalesce to one main turn however many came.
/// The lane's parse and set_grid are the test's recorder, so no Ghostty surface is made.
@Suite(.timeLimit(.minutes(1))) struct TerminalEventRouterTests {
    static var surface: ghostty_surface_t { unsafeBitCast(UInt(0x1000), to: ghostty_surface_t.self) }

    /// A router over a recording lane, with a mailbox that counts its main-turn requests.
    private struct Fixture {
        let steps: StepLog
        let lane: TerminalOutputLane
        let mailbox: TerminalEventMailbox
        let router: TerminalEventRouter

        init(label: String) {
            let steps = StepLog()
            self.steps = steps
            lane = TerminalOutputLane(surface: TerminalEventRouterTests.surface, label: label,
                                      parse: { _, data in steps.append("output \(String(decoding: data, as: UTF8.self))") },
                                      setGrid: { _, columns, rows, generation in steps.append("grid \(columns)x\(rows) #\(generation)") })
            mailbox = TerminalEventMailbox {}
            // The session's input goes nowhere here.
            let input = TerminalInputLane(drain: TerminalInputDrain(queue: DispatchQueue(label: "\(label).input", qos: .utility)) { _, _ in .next })
            router = TerminalEventRouter(lane: lane, mailbox: mailbox,
                                         input: TerminalInputSink(lane: input, typingSurface: TypingLatencyProbe(path: nil).makeSurfaceKey()),
                                         replace: { _ in nil })
        }
    }

    /// With the main actor held, output and `.resize` steps reach the lane in stream order, each new grid at
    /// the lane's next generation and a repeated grid not at all; the main actor's side waits in the mailbox.
    @MainActor @Test func outputAndGridStepsReachTheLaneInOrderWithMainHeld() async {
        let fixture = Fixture(label: "test.router-order")
        defer { fixture.lane.close() }
        let routed = DispatchSemaphore(value: 0)
        let lane = fixture.lane, start = fixture.router
        Task.detached {
            var router = start
            for event: TerminalIOEvent in [.output(Data("a".utf8)), .resize(cols: 80, rows: 24), .output(Data("b".utf8)),
                                           .resize(cols: 80, rows: 24), .resize(cols: 100, rows: 30), .output(Data("c".utf8))] {
                _ = await router.route(event)
            }
            await lane.drained()
            routed.signal()
        }
        // Holds the main actor: the loop must finish without it.
        let finished = routed.wait(timeout: .now() + 10) == .success
        #expect(finished, "the events loop waited for the main actor")
        #expect(fixture.steps.entries == ["output a", "grid 80x24 #1", "output b", "grid 100x30 #2", "output c"])
        #expect(fixture.lane.gridLock.locked == TerminalGridSize(columns: 100, rows: 30))
        let pending = fixture.mailbox.take()
        #expect(pending?.grid == TerminalGridSize(columns: 100, rows: 30))
        #expect(pending?.contentQueued == true)
    }

    /// A busy terminal's statuses, chips and grids ask the main actor for one turn until it takes them,
    /// and the turn sees the latest of each.
    @Test func statusAndGridCoalesceToOneMainTurn() async {
        let fixture = Fixture(label: "test.router-coalesce")
        defer { fixture.lane.close() }
        var router = fixture.router
        let chip = TerminalSizedFor(deviceName: "iPad", deviceKind: "ipad", sameDevice: false,
                                    grid: TerminalGridSize(columns: 60, rows: 20), fixedSize: false)
        for index in 0..<500 {
            _ = await router.route(.output(Data("x".utf8)))
            _ = await router.route(.status(index.isMultiple(of: 2) ? .restoring : .connected))
            _ = await router.route(.resize(cols: 80 + index % 3, rows: 24))
        }
        _ = await router.route(.sizedFor(chip))
        #expect(fixture.mailbox.deliveries == 1, "a busy terminal asked the main actor for more than one turn")
        let pending = fixture.mailbox.take()
        #expect(pending?.status == .connected)
        #expect(pending?.sizedFor == .some(chip))
        #expect(pending?.grid == TerminalGridSize(columns: 80 + 499 % 3, rows: 24))
        #expect(fixture.mailbox.take() == nil)

        _ = await router.route(.status(.exited))
        #expect(fixture.mailbox.deliveries == 2, "the next change after the main turn asked for no turn")
        await fixture.lane.drained()
    }

    /// A status that is not connected clears a chip queued before it, as the view does when it
    /// applies them one by one; an exit after a status stands, one before it is the status's to say.
    @Test func coalescedStatusKeepsTheOneByOneResult() {
        let chip = TerminalSizedFor(deviceName: nil, deviceKind: "mac", sameDevice: true,
                                    grid: TerminalGridSize(columns: 80, rows: 24), fixedSize: false)
        var pending = TerminalEventMailbox.Pending()
        pending.sizedFor = .some(chip)
        pending.set(.disconnected(.streamEnded, reconnecting: true))
        pending.set(.connected)
        #expect(pending.sizedFor == .some(nil))

        pending.exited = true
        pending.set(.connected)
        #expect(!pending.exited)
        pending.exited = true
        #expect(pending.exited)
    }

    /// The lane's grid lock: each new grid takes the next generation, the locked grid none, and an adopted
    /// grid (a local-history restore) is locked without a generation.
    @Test func gridLockGenerations() {
        let lock = TerminalGridLock()
        #expect(lock.locked == nil && lock.generation == 0)
        #expect(lock.next(TerminalGridSize(columns: 80, rows: 24))?.generation == 1)
        #expect(lock.next(TerminalGridSize(columns: 80, rows: 24)) == nil)
        lock.adopt(TerminalGridSize(columns: 90, rows: 30))
        #expect(lock.locked == TerminalGridSize(columns: 90, rows: 30) && lock.generation == 1)
        #expect(lock.next(TerminalGridSize(columns: 90, rows: 30)) == nil)
        let next = lock.next(TerminalGridSize(columns: 120, rows: 40))
        #expect(next?.columns == 120 && next?.rows == 40 && next?.generation == 2)
        #expect(lock.next(TerminalGridSize(columns: 70_000, rows: 24)) == nil, "a grid past 16 bits locked")
    }
}

/// What reached the lane, in order.
private nonisolated final class StepLog: Sendable { // appended to on the output lane
    private let steps = Mutex<[String]>([])
    var entries: [String] { steps.withLock { $0 } }
    func append(_ step: String) { steps.withLock { $0.append(step) } }
}
