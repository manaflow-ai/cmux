import Darwin
import Foundation
import Testing
@testable import CmuxSocketObservability

@Suite
struct MachThreadStackAddressSamplerTests {
    @Test
    func rejectsCallingThreadCapture() {
        let thread = pthread_mach_thread_np(pthread_self())
        #expect(MachThreadStackAddressSampler.captureAddresses(for: thread, maxFrames: 64).isEmpty)
    }

    @Test
    func rejectsEmptyAndInvalidCaptures() {
        #expect(MachThreadStackAddressSampler.captureAddresses(for: 0, maxFrames: 64).isEmpty)
        #expect(MachThreadStackAddressSampler.captureAddresses(for: 0, maxFrames: 0).isEmpty)
        #expect(MachThreadStackAddressSampler.captureAddresses(for: 0, maxFrames: -1).isEmpty)
    }

    @Test(.timeLimit(.minutes(1)))
    func capturesWorkerStackWithoutStoppingWorker() async throws {
        let started = AsyncStream<thread_act_t>.makeStream()
        let release = DispatchSemaphore(value: 0)
        let finished = AsyncStream<Bool>.makeStream()
        Thread.detachNewThread {
            started.continuation.yield(pthread_mach_thread_np(pthread_self()))
            started.continuation.finish()
            release.wait()
            finished.continuation.yield(true)
            finished.continuation.finish()
        }
        defer { release.signal() }
        var iterator = started.stream.makeAsyncIterator()
        let thread = try #require(await iterator.next())
        let addresses = MachThreadStackAddressSampler.captureAddresses(for: thread, maxFrames: 64)
        #expect(!addresses.isEmpty)
        #expect(addresses.count <= 64)
        #expect(addresses.allSatisfy { $0 != 0 })
        let symbols = SocketCommandBacktraceSymbolicator.symbolicate(addresses)
        #expect(symbols.count == addresses.count)
        #expect(symbols.contains { !$0.contains("<unknown>") })
        release.signal()
        var finishedIterator = finished.stream.makeAsyncIterator()
        #expect(await finishedIterator.next() == true)
    }
}
