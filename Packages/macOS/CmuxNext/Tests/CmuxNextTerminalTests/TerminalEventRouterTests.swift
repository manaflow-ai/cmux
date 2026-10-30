import CmuxNextCompat
@testable import CmuxNextTerminal
@testable import CmuxNextWakeups
import Dispatch
import Foundation
import GhosttyNextKit
import Testing

/// A session's events loop never waits for the main actor: output and grid locks
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

        /// - Parameters:
        ///   - restores: What Ghostty answers a READY (`ghostty_surface_restore_snapshot`).
        ///   - localHistory: What Ghostty answers a local-history READY (a `GHOSTTY_SURFACE_LOCAL_HISTORY_*`).
        init(label: String, restores: Bool = true,
             localHistory: Int32 = Int32(GHOSTTY_SURFACE_LOCAL_HISTORY_RESTORED.rawValue)) {
            let steps = StepLog()
            self.steps = steps
            lane = TerminalOutputLane(surface: TerminalEventRouterTests.surface, label: label,
                                      parse: { _, data in steps.append("output \(String(decoding: data, as: UTF8.self))") },
                                      setGrid: { _, columns, rows, generation in steps.append("grid \(columns)x\(rows) #\(generation)") },
                                      restore: { _, _, _ in
                                          steps.append("restore")
                                          return restores
                                      },
                                      restoreLocal: { _, _, _, _ in
                                          steps.append("restore local")
                                          return localHistory
                                      })
            mailbox = TerminalEventMailbox {}
            // The session's input goes nowhere here.
            let input = TerminalInputLane(drain: TerminalInputDrain(queue: DispatchQueue(label: "\(label).input", qos: .utility)) { _, _ in .next })
            // A swap is recorded and ends the loop (nil: the session is gone).
            router = TerminalEventRouter(lane: lane, mailbox: mailbox,
                                         input: TerminalInputSink(lane: input, typingSurface: TypingLatencyProbe(path: nil).makeSurfaceKey()),
                                         replace: { _ in
                                             steps.append("swap")
                                             return nil
                                         })
        }
    }

    /// A READY Ghostty refused is no content: the main actor hears of none, and the next replay goes
    /// into the same surface instead of swapping it. A READY that restored is content, and a replay
    /// after it swaps.
    @Test func refusedReadyIsNoContent() async {
        let fixture = Fixture(label: "test.router-ready-refused", restores: false)
        defer { fixture.lane.close {} }
        var router = fixture.router
        #expect(await router.route(.snapshot(Data("snap".utf8), phase: .ready)))
        await fixture.lane.drained()
        let afterReady = fixture.mailbox.take()
        #expect(afterReady?.contentQueued != true, "a refused READY was posted as content")
        #expect(afterReady?.readyRestores ?? 0 == 0)
        #expect(!router.hasContent)

        #expect(await router.route(.replay(Data("vt".utf8))), "a replay after a refused READY swapped the surface")
        await fixture.lane.drained()
        #expect(fixture.steps.entries == ["restore", "output vt"])
        #expect(fixture.mailbox.take()?.contentQueued == true)

        let restoring = Fixture(label: "test.router-ready-restored")
        defer { restoring.lane.close {} }
        var restored = restoring.router
        #expect(await restored.route(.snapshot(Data("snap".utf8), phase: .ready)))
        await restoring.lane.drained()
        let pending = restoring.mailbox.take()
        #expect(pending?.contentQueued == true)
        #expect(pending?.readyRestores == 1)
        #expect(!(await restored.route(.replay(Data("vt".utf8)))))
        #expect(restoring.steps.entries == ["restore", "swap"])
    }

    /// A local-history READY that Ghostty answers with an error changed nothing: no content, and the
    /// next replay goes into the same surface. A mismatch restored the READY without history: content.
    @Test func localHistoryErrorIsNoContent() async {
        let local = TerminalSnapshotPhase.readyLocalHistory(
            TerminalLocalHistory(columns: 80, rows: 24, historyRows: 10, digest: Data([1, 2, 3])))
        let fixture = Fixture(label: "test.router-local-error", localHistory: Int32(GHOSTTY_SURFACE_LOCAL_HISTORY_ERROR.rawValue))
        defer { fixture.lane.close {} }
        var router = fixture.router
        #expect(await router.route(.snapshot(Data("snap".utf8), phase: local)))
        await fixture.lane.drained()
        let afterError = fixture.mailbox.take()
        #expect(afterError?.contentQueued != true, "a local-history error was posted as content")
        #expect(afterError?.localHistoryMismatches == 1)
        #expect(await router.route(.replay(Data("vt".utf8))), "a replay after a local-history error swapped the surface")
        await fixture.lane.drained()
        #expect(fixture.steps.entries == ["restore local", "output vt"])

        let mismatch = Fixture(label: "test.router-local-mismatch", localHistory: Int32(GHOSTTY_SURFACE_LOCAL_HISTORY_MISMATCH.rawValue))
        defer { mismatch.lane.close {} }
        var mismatched = mismatch.router
        #expect(await mismatched.route(.snapshot(Data("snap".utf8), phase: local)))
        await mismatch.lane.drained()
        #expect(mismatch.mailbox.take()?.contentQueued == true)
        #expect(!(await mismatched.route(.replay(Data("vt".utf8)))))
        #expect(mismatch.steps.entries == ["restore local", "swap"])
    }

    /// With the main actor held, output and `.resize` steps reach the lane in stream order, each new grid at
    /// the lane's next generation and a repeated grid not at all; the main actor's side waits in the mailbox.
    /// Synchronous on purpose: the test body is the main actor's turn, and it holds that turn on the semaphore
    /// until the detached loop is done, so the loop provably never needed the main actor.
    @MainActor @Test func outputAndGridStepsReachTheLaneInOrderWithMainHeld() {
        let fixture = Fixture(label: "test.router-order")
        defer { fixture.lane.close {} }
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
        defer { fixture.lane.close {} }
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

        // One by one, a chip that arrives while restoring is hidden, and `.connected` does not show it again.
        var restoring = TerminalEventMailbox.Pending()
        restoring.set(.restoring)
        restoring.setSizedFor(chip)
        restoring.set(.connected)
        #expect(restoring.sizedFor == .some(nil), "a chip that came while restoring showed after connected")

        // A chip after `.connected` shows; with no pending status the main actor checks the view's connection.
        var connected = TerminalEventMailbox.Pending()
        connected.set(.restoring)
        connected.setSizedFor(chip)
        connected.set(.connected)
        connected.setSizedFor(chip)
        #expect(connected.sizedFor == .some(chip))
        var noStatus = TerminalEventMailbox.Pending()
        noStatus.setSizedFor(chip)
        #expect(noStatus.sizedFor == .some(chip))
    }

    /// The router records the stream `.restoring`, chip, `.connected` as one by one: no chip.
    @Test func chipWhileRestoringStaysHidden() async {
        let fixture = Fixture(label: "test.router-chip-restoring")
        defer { fixture.lane.close {} }
        var router = fixture.router
        let chip = TerminalSizedFor(deviceName: "iPad", deviceKind: "ipad", sameDevice: false,
                                    grid: TerminalGridSize(columns: 60, rows: 20), fixedSize: false)
        _ = await router.route(.status(.restoring))
        _ = await router.route(.sizedFor(chip))
        _ = await router.route(.status(.connected))
        let pending = fixture.mailbox.take()
        #expect(pending?.status == .connected)
        #expect(pending?.sizedFor == .some(nil))
        await fixture.lane.drained()
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
