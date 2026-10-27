import CmuxNextCompat
@testable import CmuxNextTerminal
@testable import CmuxNextWakeups
import Dispatch
import Foundation
import GhosttyNextKit
import Testing

/// The events loop across a hidden terminal's surface release and rebuild (p01-process-140): while released it
/// parses nothing and still posts the grid and status the main actor shows; after the rebuild it takes the
/// fresh surface's lane before its next event, and that lane starts with no content.
@Suite(.timeLimit(.minutes(1))) struct TerminalSurfaceReleaseRouterTests {
    private static var surface: ghostty_surface_t { unsafeBitCast(UInt(0x1000), to: ghostty_surface_t.self) }

    private static func lane(_ label: String, log: ReleaseStepLog) -> TerminalOutputLane {
        TerminalOutputLane(surface: surface, label: label,
                           parse: { _, data in log.append("\(label) output \(String(decoding: data, as: UTF8.self))") },
                           setGrid: { _, columns, rows, _ in log.append("\(label) grid \(columns)x\(rows)") },
                           restore: { _, _, _ in
                               log.append("\(label) restore")
                               return true
                           })
    }

    @Test func releasedSurfaceParsesNothingAndTheRebuiltLaneTakesWhatFollows() async {
        let log = ReleaseStepLog()
        let first = Self.lane("first", log: log), rebuilt = Self.lane("rebuilt", log: log)
        defer {
            first.close()
            rebuilt.close()
        }
        let epoch = TerminalSurfaceEpoch()
        let current = HandoffSlot(TerminalLaneHandoff(lane: first, epoch: 0, released: false))
        let mailbox = TerminalEventMailbox {}
        let input = TerminalInputLane(drain: TerminalInputDrain(queue: DispatchQueue(label: "test.release.input", qos: .utility)) { _, _ in .next })
        var router = TerminalEventRouter(lane: first, mailbox: mailbox,
                                         input: TerminalInputSink(lane: input, typingSurface: TypingLatencyProbe(path: nil).makeSurfaceKey()),
                                         epoch: epoch, handoff: { current.value },
                                         replace: { _ in
                                             log.append("swap")
                                             return nil
                                         })

        #expect(await router.route(.output(Data("a".utf8))))
        await first.drained()
        #expect(mailbox.take()?.contentQueued == true)

        // The grace ended: the session swapped in a stand-in with no lane.
        current.value = TerminalLaneHandoff(lane: nil, epoch: 1, released: true)
        epoch.advance()
        #expect(await router.route(.output(Data("lost".utf8))))
        #expect(await router.route(.replay(Data("reattach".utf8))), "a replay while released swapped a surface")
        #expect(await router.route(.snapshot(Data("snap".utf8), phase: .ready)))
        #expect(await router.route(.resize(cols: 100, rows: 30)))
        #expect(await router.route(.status(.connected)))
        #expect(router.released)
        let whileReleased = mailbox.take()
        #expect(whileReleased?.grid == TerminalGridSize(columns: 100, rows: 30), "a released terminal lost its grid")
        #expect(whileReleased?.status == .connected)
        #expect(whileReleased?.contentQueued != true, "content was posted for a released surface")

        // Shown again: a fresh surface. The stream's output before the owner's READY is a fragment: parsed
        // into the empty surface it would show with default modes and end the frame hold.
        current.value = TerminalLaneHandoff(lane: rebuilt, epoch: 2, released: false)
        epoch.advance()
        #expect(await router.route(.output(Data("fragment".utf8))))
        #expect(await router.route(.snapshot(Data("hist".utf8), phase: .history)))
        await rebuilt.drained()
        #expect(router.awaitsScreen)
        #expect(log.entries == ["first output a"], "output before the READY reached the rebuilt surface")
        #expect(mailbox.take()?.contentQueued != true, "output before the READY ended the frame hold")

        // The READY and the tail after it.
        #expect(await router.route(.snapshot(Data("snap".utf8), phase: .ready)))
        #expect(await router.route(.output(Data("tail".utf8))))
        await rebuilt.drained()
        #expect(!router.released)
        #expect(!router.awaitsScreen)
        #expect(log.entries == ["first output a", "rebuilt restore", "rebuilt output tail"])
        #expect(mailbox.take()?.contentQueued == true, "the rebuilt surface's content never reached the main actor")
    }

    @Test func aByteModeReplayRebuildsTheScreenAfterTheFragmentBeforeIt() async {
        let log = ReleaseStepLog()
        let rebuilt = Self.lane("rebuilt", log: log)
        defer { rebuilt.close() }
        let epoch = TerminalSurfaceEpoch()
        let current = HandoffSlot(TerminalLaneHandoff(lane: nil, epoch: 0, released: true))
        let mailbox = TerminalEventMailbox {}
        let input = TerminalInputLane(drain: TerminalInputDrain(queue: DispatchQueue(label: "test.release.bytes", qos: .utility)) { _, _ in .next })
        var router = TerminalEventRouter(lane: nil, mailbox: mailbox,
                                         input: TerminalInputSink(lane: input, typingSurface: TypingLatencyProbe(path: nil).makeSurfaceKey()),
                                         epoch: epoch, handoff: { current.value },
                                         replace: { _ in
                                             log.append("swap")
                                             return nil
                                         })
        // Released, then shown again before the loop's next event.
        epoch.advance()
        current.value = TerminalLaneHandoff(lane: rebuilt, epoch: 2, released: false)
        epoch.advance()
        #expect(await router.route(.output(Data("fragment".utf8))))
        #expect(mailbox.take()?.contentQueued != true)
        #expect(await router.route(.replay(Data("screen".utf8))))
        #expect(await router.route(.output(Data("tail".utf8))))
        await rebuilt.drained()
        #expect(log.entries == ["rebuilt output screen", "rebuilt output tail"], "the replay did not go into the rebuilt surface")
        #expect(mailbox.take()?.contentQueued == true)
    }

    @Test func aSessionGoneDuringTheHandoffEndsTheLoop() async {
        let epoch = TerminalSurfaceEpoch()
        let input = TerminalInputLane(drain: TerminalInputDrain(queue: DispatchQueue(label: "test.release.gone", qos: .utility)) { _, _ in .next })
        var router = TerminalEventRouter(lane: nil, mailbox: TerminalEventMailbox {},
                                         input: TerminalInputSink(lane: input, typingSurface: TypingLatencyProbe(path: nil).makeSurfaceKey()),
                                         epoch: epoch, handoff: { nil }, replace: { _ in nil })
        #expect(await router.route(.status(.connected)), "the loop ended with no surface change")
        epoch.advance()
        #expect(!(await router.route(.status(.connected))), "the loop outlived its session")
    }
}

/// The session's current lane, as the test sets it.
private nonisolated final class HandoffSlot: Sendable {
    private let slot: Mutex<TerminalLaneHandoff>
    init(_ handoff: TerminalLaneHandoff) { slot = Mutex(handoff) }
    var value: TerminalLaneHandoff {
        get { slot.withLock { $0 } }
        set { slot.withLock { $0 = newValue } }
    }
}

/// What reached the lanes, in order.
private nonisolated final class ReleaseStepLog: Sendable { // appended to on the output lanes
    private let steps = Mutex<[String]>([])
    var entries: [String] { steps.withLock { $0 } }
    func append(_ step: String) { steps.withLock { $0.append(step) } }
}
