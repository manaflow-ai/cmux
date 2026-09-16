import Dispatch
import Foundation
import Testing
@testable import CmuxFoundation

@Suite("FSEvents nonblocking lifecycle", .timeLimit(.minutes(1)))
struct FileSystemEventStreamLifecycleTests {
    @MainActor
    @Test func releasingStreamDoesNotWaitForEventQueue() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-stream-lifetime-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let queue = DispatchQueue(label: "cmux.test.stream-lifetime")
        var stream = await FileSystemEventStream.start(
            paths: [directory.path], latency: 0, onEvent: { _ in }, queue: queue
        )
        #expect(stream != nil)
        weak var releasedStream = stream
        let (blocked, continuation) = AsyncStream<Void>.makeStream()
        let release = DispatchSemaphore(value: 0)
        defer { release.signal(); continuation.finish() }
        queue.async {
            continuation.yield(())
            #expect(release.wait(timeout: .now() + 5) == .success)
        }
        var iterator = blocked.makeAsyncIterator()
        _ = await iterator.next()
        stream = nil
        #expect(releasedStream == nil)
        release.signal()
        // Native teardown is ahead of this fence on the same serial queue.
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume() }
        }
    }

    @MainActor
    @Test func registrationWaitDoesNotOccupyMainActor() async throws {
        let queue = DispatchQueue(label: "cmux.test.stream-start")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        queue.async {
            #expect(release.wait(timeout: .now() + 5) == .success)
        }
        let registration = Task {
            await FileSystemEventStream.start(paths: [], latency: 0, onEvent: { _ in }, queue: queue)
        }
        // The queue can be held while the caller continues to do UI work.
        release.signal()
        #expect(await registration.value == nil)
    }
}
