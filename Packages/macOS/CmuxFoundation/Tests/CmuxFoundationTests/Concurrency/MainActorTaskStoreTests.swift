import Foundation
import Testing

@testable import CmuxFoundation

@Suite(.serialized)
struct MainActorTaskStoreTests {
    private final class CancellationFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false

        func mark() {
            lock.withLock { value = true }
        }

        var isMarked: Bool {
            lock.withLock { value }
        }
    }

    /// Lock-protected because task-context destruction may occur off-main.
    private final class ReleaseStackRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var minimumAddress = UInt.max
        private var maximumAddress: UInt = 0
        private var releaseCount = 0
        private var mainThreadReleaseCount = 0

        func record(address: UInt, isMainThread: Bool) {
            lock.lock()
            releaseCount += 1
            if isMainThread {
                mainThreadReleaseCount += 1
                minimumAddress = min(minimumAddress, address)
                maximumAddress = max(maximumAddress, address)
            }
            lock.unlock()
        }

        var snapshot: (count: Int, mainThreadCount: Int, addressSpan: UInt) {
            lock.lock()
            defer { lock.unlock() }
            let span = minimumAddress == UInt.max ? 0 : maximumAddress - minimumAddress
            return (releaseCount, mainThreadReleaseCount, span)
        }
    }

    /// Immutable after initialization, so cross-task capture is safe.
    private final class ClosureLifetimeProbe: @unchecked Sendable {
        let identifier: Int
        let recorder: ReleaseStackRecorder
        let deinitialized: AsyncStream<Int>.Continuation

        init(
            identifier: Int,
            recorder: ReleaseStackRecorder,
            deinitialized: AsyncStream<Int>.Continuation
        ) {
            self.identifier = identifier
            self.recorder = recorder
            self.deinitialized = deinitialized
        }

        deinit {
            var stackMarker: UInt8 = 0
            let address = withUnsafePointer(to: &stackMarker) {
                UInt(bitPattern: UnsafeRawPointer($0))
            }
            recorder.record(address: address, isMainThread: Thread.isMainThread)
            deinitialized.yield(identifier)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    @MainActor
    func replacementBurstKeepsReleaseStackBounded() async throws {
        let replacementCount = 5_000
        let recorder = ReleaseStackRecorder()
        let deinitializations = AsyncStream<Int>.makeStream()
        defer { deinitializations.continuation.finish() }
        var deinitializationIterator = deinitializations.stream.makeAsyncIterator()
        let actions = AsyncStream<Int>.makeStream()
        defer { actions.continuation.finish() }
        var actionIterator = actions.stream.makeAsyncIterator()
        let releaseOperations = AsyncStream<Void>.makeStream()
        let store = MainActorTaskStore<String>()

        for identifier in 0..<replacementCount {
            let probe = ClosureLifetimeProbe(
                identifier: identifier,
                recorder: recorder,
                deinitialized: deinitializations.continuation
            )
            store.replaceOnMainActor("search") {
                for await _ in releaseOperations.stream {}
                guard !Task.isCancelled else { return }
                _ = probe
                actions.continuation.yield(identifier)
            }
        }
        releaseOperations.continuation.finish()

        let fired = try #require(await actionIterator.next())
        #expect(fired == replacementCount - 1)

        var deinitializedIdentifiers: Set<Int> = []
        for _ in 0..<replacementCount {
            let identifier = try #require(await deinitializationIterator.next())
            deinitializedIdentifiers.insert(identifier)
        }
        #expect(deinitializedIdentifiers == Set(0..<replacementCount))

        let snapshot = recorder.snapshot
        #expect(snapshot.count == replacementCount)
        #expect(snapshot.mainThreadCount == replacementCount)
        #expect(snapshot.addressSpan < 512 * 1_024)
    }

    @Test(.timeLimit(.minutes(1)))
    @MainActor
    func releasingStoreCancelsSuspendedOperation() async throws {
        let started = AsyncStream<Void>.makeStream()
        defer { started.continuation.finish() }
        var startedIterator = started.stream.makeAsyncIterator()
        let cancelled = AsyncStream<Void>.makeStream()
        defer { cancelled.continuation.finish() }
        var cancelledIterator = cancelled.stream.makeAsyncIterator()
        let cancellationFlag = CancellationFlag()
        let suspension = AsyncStream<Void>.makeStream()
        defer { suspension.continuation.finish() }
        var store: MainActorTaskStore<String>? = MainActorTaskStore()
        weak var weakStore: MainActorTaskStore<String>?
        weakStore = store

        store?.replace("search") {
            await withTaskCancellationHandler {
                started.continuation.yield()
                for await _ in suspension.stream {}
            } onCancel: {
                cancellationFlag.mark()
                cancelled.continuation.yield()
            }
        }

        _ = try #require(await startedIterator.next())
        store = nil
        #expect(weakStore == nil)
        #expect(cancellationFlag.isMarked)
        _ = try #require(await cancelledIterator.next())
    }

    @Test(.timeLimit(.minutes(1)))
    @MainActor
    func staleOperationCompletionCannotClearSuccessor() async throws {
        let firstMayFinish = AsyncStream<Void>.makeStream()
        defer { firstMayFinish.continuation.finish() }
        let firstFinished = AsyncStream<Void>.makeStream()
        defer { firstFinished.continuation.finish() }
        var firstFinishedIterator = firstFinished.stream.makeAsyncIterator()
        let secondMayFinish = AsyncStream<Void>.makeStream()
        defer { secondMayFinish.continuation.finish() }
        let store = MainActorTaskStore<String>()

        store.replace("search") {
            for await _ in firstMayFinish.stream {}
            firstFinished.continuation.yield()
        }
        store.replace("search") {
            for await _ in secondMayFinish.stream {}
        }

        firstMayFinish.continuation.finish()
        _ = try #require(await firstFinishedIterator.next())
        #expect(store.contains("search"))
        store.cancel("search")
        #expect(!store.contains("search"))
    }
}
