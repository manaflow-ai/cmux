import CmuxNextCompat
@testable import CmuxNextTrace
import Foundation
import Testing

/// A checked blocking call is one `task.blocking_call` slice while the routing runtime's `task` category records,
/// and none while it is off (plans/cmux-next/trace.md "Blocking calls and lane jobs"). Each test
/// routes the process's blocking calls into its own runtime and ring; other tests' calls on other threads may land
/// there too, so the checks read only this file's sites.
@Suite(.serialized)
struct BlockingCallTraceTests {
    private static let fileHash = TraceRuntime.fileIDHash(#fileID)

    /// A runtime that routes the process's blocking calls, with its own ring.
    private static func routingRuntime() -> (TraceRuntime, TraceRing) {
        let runtime = TraceRuntime(role: .app, clock: TraceClock(), stubRecorder: nil, routesBlockingCalls: true)
        let ring = TraceRing(records: 4_096, role: .app)
        runtime.attach(ring)
        return (runtime, ring)
    }

    /// The records of this file's blocking calls: a begin carries the file's hash; its end is the next
    /// `task.blocking_call` end on the same thread.
    private static func ownSlices(_ ring: TraceRing) throws -> [TraceRecord] {
        let image = try #require(ring.decodedImage())
        let named = image.records.filter { image.name(of: $0) == "task.blocking_call" }
        var own: [TraceRecord] = []
        var open: Set<UInt32> = []
        for record in named {
            if record.phase == .begin, record.arg1 == fileHash {
                own.append(record)
                open.insert(record.threadIndex)
            } else if record.phase == .end, open.remove(record.threadIndex) != nil {
                own.append(record)
            }
        }
        return own
    }

    @Test("Tracing on: one blocking call is one begin and one end with its kind and line")
    func onWritesOneSlice() throws {
        let (runtime, ring) = Self.routingRuntime()
        runtime.setCategories(.task)
        defer { runtime.setCategories([]) }
        #expect(BlockingTraceHook.isRecording)

        let line: UInt = #line + 1
        let value = blockingCall(.fileIO) { 42 }

        #expect(value == 42)
        let slices = try Self.ownSlices(ring)
        #expect(slices.map(\.phase) == [.begin, .end])
        #expect(slices.first?.arg0 == UInt64(BlockingKind.fileIO.traceCode) | UInt64(line) << 8)
    }

    @Test("Tracing on: a CPU-intensive call is one cpu-intensive slice at its line, whatever its size")
    func cpuIntensiveCallWritesOneSlice() throws {
        let (runtime, ring) = Self.routingRuntime()
        runtime.setCategories(.task)
        defer { runtime.setCategories([]) }

        let line: UInt = #line + 1
        let value = cpuIntensiveCall(size: 1, limit: 1_024) { 7 }

        #expect(value == 7)
        let slices = try Self.ownSlices(ring)
        #expect(slices.map(\.phase) == [.begin, .end])
        #expect(slices.first?.arg0 == UInt64(BlockingKind.cpuIntensive.traceCode) | UInt64(line) << 8)
        #expect(BlockingKind.cpuIntensive.traceCode == 12)
    }

    @Test("A thrown error still ends the slice")
    func aThrowEndsTheSlice() throws {
        struct Failed: Error {}
        let (runtime, ring) = Self.routingRuntime()
        runtime.setCategories(.task)
        defer { runtime.setCategories([]) }

        #expect(throws: Failed.self) { try blockingCall(.sleep) { () throws(Failed) in throw Failed() } }

        #expect(try Self.ownSlices(ring).map(\.phase) == [.begin, .end])
    }

    @Test("Tracing off: no slice, and the hook is clear")
    func offWritesNothing() throws {
        let (runtime, ring) = Self.routingRuntime()
        runtime.setCategories(.blackBox)
        #expect(!BlockingTraceHook.isRecording)

        blockingCall(.fileIO) {}

        #expect(try Self.ownSlices(ring).isEmpty)
    }

    @Test("Turning the task category off clears the hook; a runtime that does not route never sets it")
    func theCategoryDrivesTheHook() {
        let (runtime, _) = Self.routingRuntime()
        runtime.setCategories(.task)
        #expect(BlockingTraceHook.isRecording)
        runtime.setCategories([])
        #expect(!BlockingTraceHook.isRecording)

        let plain = TraceRuntime(role: .app)
        plain.setCategories(.all)
        #expect(!BlockingTraceHook.isRecording)
    }

    @Test("A stop by another runtime leaves the recording runtime's hook in place")
    func anotherRuntimesStopKeepsTheHook() {
        let (recording, _) = Self.routingRuntime()
        let (other, _) = Self.routingRuntime()
        recording.setCategories(.task)
        defer { recording.setCategories([]) }
        other.setCategories([])
        #expect(BlockingTraceHook.isRecording)
    }

    @Test("Every kind has its own fixed trace code")
    func kindCodesAreUnique() {
        let codes = BlockingKind.allCases.map(\.traceCode)
        #expect(Set(codes).count == codes.count)
        #expect(!codes.contains(0))
        #expect(BlockingKind.fileIO.traceCode == 1)
        #expect(BlockingKind.systemQuery.traceCode == 16)
        #expect(BlockingKind.xpcReply.traceCode == 19)
    }

    @Test("The file hash is FNV-1a 64 of the fileID's bytes")
    func fileHashIsFNV1a() {
        #expect(TraceRuntime.fileIDHash("") == 0xcbf2_9ce4_8422_2325)
        #expect(TraceRuntime.fileIDHash("a") == 0xaf63_dc4c_8601_ec8c)
    }
}
