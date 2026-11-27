import Dispatch
import Foundation
import Testing
@testable import CmuxFoundation

@Suite("FSEvents nonblocking lifecycle")
struct FileSystemEventStreamLifecycleTests {
    private final class WeakReference<Value: AnyObject> {
        weak var value: Value?
        init(_ value: Value?) { self.value = value }
    }

    private final class LifetimeMarker: Sendable {
        let completion: AsyncStream<Void>.Continuation

        init(completion: AsyncStream<Void>.Continuation) { self.completion = completion }
        deinit { completion.yield(()); completion.finish() }
    }

    @MainActor
    @Test func releasingStreamDoesNotWaitForEventQueue() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-stream-lifetime-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let queue = DispatchQueue(label: "cmux.test.stream-lifetime")
        let (released, completion) = AsyncStream<Void>.makeStream()
        var marker: LifetimeMarker? = LifetimeMarker(completion: completion)
        let retainedMarker = WeakReference(marker)
        var stream = await FileSystemEventStream.start(
            paths: [directory.path], latency: 0,
            onEvent: { [marker] _ in withExtendedLifetime(marker) {} }, queue: queue
        )
        marker = nil
        #expect(stream != nil)
        let releasedStream = WeakReference(stream)
        let (blocked, continuation) = AsyncStream<Void>.makeStream()
        let release = DispatchSemaphore(value: 0)
        defer { release.signal(); continuation.finish() }
        queue.async {
            continuation.yield(())
            release.wait()
        }
        var iterator = blocked.makeAsyncIterator()
        _ = await iterator.next()
        stream = nil
        #expect(releasedStream.value == nil)
        #expect(retainedMarker.value != nil, "FSEvents must retain its receiver until native teardown runs.")
        release.signal()
        // Native teardown is ahead of this fence on the same serial queue.
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume() }
        }
        // FSEvents can release its context from an internal queue after our
        // lifecycle block returns. Await that actual ownership event.
        var releaseIterator = released.makeAsyncIterator()
        _ = await releaseIterator.next()
        #expect(retainedMarker.value == nil, "Native teardown must release the callback graph.")
    }

    @MainActor
    @Test func registrationWaitDoesNotOccupyMainActor() async throws {
        let queue = DispatchQueue(label: "cmux.test.stream-start")
        let release = DispatchSemaphore(value: 0)
        let (entered, enteredContinuation) = AsyncStream<Void>.makeStream()
        defer {
            release.signal()
            enteredContinuation.finish()
        }
        queue.async {
            enteredContinuation.yield(())
            release.wait()
        }
        var enteredIterator = entered.makeAsyncIterator()
        _ = await enteredIterator.next()
        let (registrationEntered, registrationContinuation) = AsyncStream<Void>.makeStream()
        defer { registrationContinuation.finish() }
        let registration = Task { @MainActor in
            registrationContinuation.yield(())
            return await FileSystemEventStream.start(paths: [], latency: 0, onEvent: { _ in }, queue: queue)
        }
        var registrationIterator = registrationEntered.makeAsyncIterator()
        _ = await registrationIterator.next()
        // The queue can be held while the caller continues to do UI work.
        release.signal()
        #expect(await registration.value == nil)
    }
}
