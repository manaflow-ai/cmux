#if DEBUG
// The Chromium host app ships in Debug builds only (embed-cef.sh), and so does its Swift side.
@testable import CmuxNextBrowser
import CmuxNextCompat
@testable import CmuxNextSignposts
@testable import CmuxNextTrace
import Darwin
import Testing

/// p09-observability-104: the input ring is the transport the host's `DispatchInput` reads, so its writer takes
/// the `cef.host_input` flow-out whose id the host's flow-in names (``ChromiumHostFrame/inputFlow(appPID:)``):
/// one per pointer frame that enters the ring while `input` records, none for a key, none with `input` off, and
/// for a move folded in the backlog, the flow of the frame that reaches the ring.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1))) struct ChromiumHostInputRingTraceTests {
    private nonisolated final class RecordLog: Sendable {
        private let state = Mutex<[TraceRuntime.StubRecord]>([])

        var flows: [TraceRuntime.StubRecord] {
            state.withLock { $0.filter { $0.name == SignpostName.cefHostInput.rawValue && $0.phase == .flowOut } }
        }

        func runtime() -> TraceRuntime {
            TraceRuntime(role: .app, clock: TraceClock(), stubRecorder: { [self] record in
                state.withLock { $0.append(record) }
            })
        }
    }

    /// A ring over its own region, recording into `log`, and this test's mapping of the region (the reader's view).
    private final class Rig {
        let log = RecordLog()
        let runtime: TraceRuntime
        let region: ChromiumHostInputRingRegion
        let ring: ChromiumHostInputRing
        private let address: Int

        init() throws {
            runtime = log.runtime()
            runtime.setCategories(.all)
            region = try ChromiumHostInputRingRegion.make()
            let mapped = mmap(nil, ChromiumHostInputRing.ringBytes, PROT_READ | PROT_WRITE, MAP_SHARED, region.fd, 0)
            let base = try #require(mapped == UnsafeMutableRawPointer(bitPattern: -1) ? nil : mapped)
            address = Int(bitPattern: base)
            ring = try ChromiumHostInputRing(region: region.fd, doorbell: nil, trace: runtime)
        }

        deinit {
            munmap(UnsafeMutableRawPointer(bitPattern: address), ChromiumHostInputRing.ringBytes)
            close(region.fd)
        }

        /// Plays the reader: takes every written frame (the head moves to the tail).
        func readAll() {
            let base = UnsafeMutableRawPointer(bitPattern: address).unsafelyUnwrapped
            let tail = AtomicPointerSlot((base + ChromiumHostInputRing.tailOffset).assumingMemoryBound(to: UInt64.self))
            let head = AtomicPointerSlot((base + ChromiumHostInputRing.headOffset).assumingMemoryBound(to: UInt64.self))
            head.store(tail.load(ordering: .acquiring), ordering: .releasing)
        }
    }

    private static func move(_ x: Int32, t0: UInt64) -> ChromiumHostFrame {
        ChromiumHostFrame(.mouse, v: [x, 0, 0, 0, 0, 0], t0: t0)
    }

    @Test func aPointerFrameEnteringTheRingIsAFlowOutTheHostFlowsInTo() throws {
        let rig = try Rig()
        let pid = UInt32(bitPattern: getpid())

        #expect(rig.ring.write(Self.move(1, t0: 1_000), browser: 7) == .written)
        #expect(rig.ring.write(ChromiumHostFrame(.wheel, v: [0, 0, 0, -3, 0, 0], t0: 2_000), browser: 7) == .written)
        #expect(rig.ring.write(ChromiumHostFrame(.key, v: [0, 0x24], t0: 3_000), browser: 7) == .written)
        #expect(rig.log.flows.map(\.arg1) == [ChromiumHostFrame.inputFlow(appPID: pid, eventTime: 1_000),
                                              ChromiumHostFrame.inputFlow(appPID: pid, eventTime: 2_000)],
                "a key has no flow: its timing is typing")
        #expect(rig.log.flows.map(\.arg0) == [ChromiumHostFrame.Kind.mouse, .wheel].map { UInt64($0.rawValue) })

        rig.runtime.setCategories(.blackBox)
        #expect(rig.ring.write(Self.move(2, t0: 4_000), browser: 7) == .written)
        #expect(rig.log.flows.count == 2, "no recording of input: no flow")
    }

    /// A full ring: two moves fold in the backlog and only the folded one, with the newer event time the host
    /// dispatches, enters the ring and flows out.
    @Test func aFoldedMoveFlowsOutOnceWithTheFrameTheHostReads() throws {
        let rig = try Rig()
        let pid = UInt32(bitPattern: getpid())
        rig.runtime.setCategories(.blackBox)
        for code in 0 ..< Int32(ChromiumHostInputRing.capacity) {
            #expect(rig.ring.write(ChromiumHostFrame(.key, v: [0, code], t0: UInt64(code + 1)), browser: 7) == .written)
        }
        rig.runtime.setCategories(.all)

        #expect(rig.ring.write(Self.move(1, t0: 10_000), browser: 7) == .spilled)
        #expect(rig.ring.write(Self.move(2, t0: 11_000), browser: 7) == .spilled)
        #expect(rig.log.flows.isEmpty, "a frame waiting in the backlog has not entered the ring")

        rig.readAll()
        #expect(rig.ring.flushBacklog() == .drained)
        #expect(rig.log.flows.map(\.arg1) == [ChromiumHostFrame.inputFlow(appPID: pid, eventTime: 11_000)])
    }
}
#endif
