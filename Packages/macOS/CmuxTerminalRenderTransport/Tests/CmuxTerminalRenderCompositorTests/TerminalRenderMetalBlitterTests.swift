import CoreFoundation
import Foundation
import IOSurface
import QuartzCore
import Testing
@testable import CmuxTerminalRenderCompositor
@testable import CmuxTerminalRenderProtocol
@testable import CmuxTerminalRenderTransport

struct TerminalRenderMetalBlitterTests {
    @Test
    @MainActor
    func dedicatedExecutorSubmitsOneFullBlitAndReleasesOnlyAfterGPUCompletion() async throws {
        let fence = try makeFence(generation: 7)
        let frame = try makeFrame(fence: fence, frameSequence: 1)
        let executor = TerminalRenderMetalExecutor(label: "test.cmux.metal.executor")
        let backend = RecordingMetalSubmissionBackend(
            executor: executor,
            results: [.submitted]
        )
        let releases = ReleaseRecorder()
        let layer = TerminalRenderMetalLayerHandle(CAMetalLayer())
        let blitter = makeBlitter(
            executor: executor,
            backend: backend,
            releases: releases,
            layer: layer
        )

        let result = await blitter.enqueue(
            frame,
            epoch: 1,
            layer: layer
        )

        #expect(result == .submitted)
        let submitted = backend.snapshot()
        #expect(submitted.submissionSequences == [1])
        #expect(submitted.commandBufferCount == 1)
        #expect(submitted.blitEncoderCount == 1)
        #expect(submitted.fullSurfaceCopyCount == 1)
        #expect(submitted.renderEncoderCount == 0)
        #expect(submitted.maximumConcurrentSubmissions == 1)
        #expect(submitted.executedOnDedicatedExecutor == [true])
        #expect(submitted.executedOnMainThread == [false])
        #expect(releases.snapshot().isEmpty)

        backend.complete(frameSequence: 1)

        #expect(releases.snapshot() == [TerminalRenderFrameRelease(frame: frame)])
        let metrics = blitter.metrics()
        #expect(metrics.submittedBlits == 1)
        #expect(metrics.gpuCompletedBlits == 1)
        #expect(metrics.releasedSurfaces == 1)
    }

    @Test
    func stopAndWaitHoldsTheReleaseFenceUntilActiveGPUCompletion() async throws {
        let fence = try makeFence(generation: 7)
        let frame = try makeFrame(fence: fence, frameSequence: 1)
        let executor = TerminalRenderMetalExecutor(
            label: "test.cmux.metal.quiescence"
        )
        let backend = RecordingMetalSubmissionBackend(
            executor: executor,
            results: [.submitted]
        )
        let releases = ReleaseRecorder()
        let layer = TerminalRenderMetalLayerHandle(CAMetalLayer())
        let blitter = makeBlitter(
            executor: executor,
            backend: backend,
            releases: releases,
            layer: layer
        )

        #expect(await blitter.enqueue(frame, epoch: 1, layer: layer) == .submitted)
        #expect(blitter.outstandingFrameLeaseCount == 1)
        let completion = BooleanRecorder()
        let stopTask = Task {
            await blitter.stopAndWait()
            completion.setTrue()
        }
        while blitter.quiescenceWaiterCount == 0, !completion.value {
            await Task.yield()
        }

        #expect(blitter.quiescenceWaiterCount == 1)
        #expect(!completion.value)
        #expect(releases.snapshot().isEmpty)
        #expect(blitter.outstandingFrameLeaseCount == 1)

        backend.complete(frameSequence: 1)
        await stopTask.value

        #expect(completion.value)
        #expect(releases.snapshot() == [TerminalRenderFrameRelease(frame: frame)])
        #expect(blitter.outstandingFrameLeaseCount == 0)
        await blitter.stopAndWait()
    }

    @Test
    func latestFrameWinsWithOneSubmissionAndOnePendingSlot() async throws {
        let fence = try makeFence(generation: 7)
        let frame1 = try makeFrame(fence: fence, frameSequence: 1)
        let frame2 = try makeFrame(fence: fence, frameSequence: 2)
        let frame3 = try makeFrame(fence: fence, frameSequence: 3)
        let executor = TerminalRenderMetalExecutor(label: "test.cmux.metal.bounded")
        let backend = RecordingMetalSubmissionBackend(
            executor: executor,
            results: [.submitted, .submitted]
        )
        let releases = ReleaseRecorder()
        let layer = TerminalRenderMetalLayerHandle(CAMetalLayer())
        let blitter = makeBlitter(
            executor: executor,
            backend: backend,
            releases: releases,
            layer: layer
        )

        #expect(await blitter.enqueue(frame1, epoch: 1, layer: layer) == .submitted)
        #expect(await blitter.enqueue(frame2, epoch: 1, layer: layer) == .coalesced)
        #expect(await blitter.enqueue(frame3, epoch: 1, layer: layer) == .coalesced)
        #expect(
            releases.snapshot()
                == [TerminalRenderFrameRelease(frame: frame2)]
        )
        #expect(backend.snapshot().submissionSequences == [1])

        backend.complete(frameSequence: 1)
        await backend.waitForSubmissionCount(2)

        #expect(backend.snapshot().submissionSequences == [1, 3])
        #expect(backend.snapshot().maximumConcurrentSubmissions == 1)
        #expect(
            releases.snapshot()
                == [
                    TerminalRenderFrameRelease(frame: frame2),
                    TerminalRenderFrameRelease(frame: frame1),
                ]
        )

        backend.complete(frameSequence: 3)

        #expect(
            releases.snapshot()
                == [
                    TerminalRenderFrameRelease(frame: frame2),
                    TerminalRenderFrameRelease(frame: frame1),
                    TerminalRenderFrameRelease(frame: frame3),
                ]
        )
        let metrics = blitter.metrics()
        #expect(metrics.submittedBlits == 2)
        #expect(metrics.gpuCompletedBlits == 2)
        #expect(metrics.coalescedFrames == 1)
        #expect(metrics.releasedSurfaces == 3)
    }

    @Test
    func drawableMissKeepsOnePendingFrameAndStopReleasesItExactlyOnce() async throws {
        let fence = try makeFence(generation: 7)
        let frame = try makeFrame(fence: fence, frameSequence: 1)
        let executor = TerminalRenderMetalExecutor(label: "test.cmux.metal.drawable")
        let backend = RecordingMetalSubmissionBackend(
            executor: executor,
            results: [.drawableUnavailable]
        )
        let releases = ReleaseRecorder()
        let layer = TerminalRenderMetalLayerHandle(CAMetalLayer())
        let blitter = makeBlitter(
            executor: executor,
            backend: backend,
            releases: releases,
            layer: layer
        )

        #expect(
            await blitter.enqueue(frame, epoch: 1, layer: layer)
                == .drawableUnavailable
        )
        #expect(releases.snapshot().isEmpty)

        blitter.stop()
        await backend.waitForInvalidationCount(1)
        blitter.stop()

        #expect(releases.snapshot() == [TerminalRenderFrameRelease(frame: frame)])
        #expect(backend.snapshot().cacheInvalidationCount == 1)
        #expect(blitter.metrics().releasedSurfaces == 1)
    }

    @Test
    func staleEpochFrameIsRejectedAndReleasedExactlyOnce() async throws {
        let fence = try makeFence(generation: 7)
        let frame = try makeFrame(fence: fence, frameSequence: 1)
        let executor = TerminalRenderMetalExecutor(label: "test.cmux.metal.stale")
        let backend = RecordingMetalSubmissionBackend(executor: executor, results: [])
        let releases = ReleaseRecorder()
        let layer = TerminalRenderMetalLayerHandle(CAMetalLayer())
        let blitter = makeBlitter(
            executor: executor,
            backend: backend,
            releases: releases,
            layer: layer
        )

        #expect(
            await blitter.enqueue(frame, epoch: 0, layer: layer)
                == .rejected(.presentationGenerationMismatch)
        )
        blitter.stop()
        await backend.waitForInvalidationCount(1)

        #expect(releases.snapshot() == [TerminalRenderFrameRelease(frame: frame)])
        #expect(backend.snapshot().submissionSequences.isEmpty)
        #expect(blitter.metrics().releasedSurfaces == 1)
    }

    @Test
    func fenceAndLayerTransitionsInvalidateCacheAndReleaseOnlyPendingFrames() async throws {
        let fence = try makeFence(generation: 7)
        let frame1 = try makeFrame(fence: fence, frameSequence: 1)
        let frame2 = try makeFrame(fence: fence, frameSequence: 2)
        let executor = TerminalRenderMetalExecutor(label: "test.cmux.metal.transition")
        let backend = RecordingMetalSubmissionBackend(
            executor: executor,
            results: [.submitted]
        )
        let releases = ReleaseRecorder()
        let oldLayer = TerminalRenderMetalLayerHandle(CAMetalLayer())
        let replacementLayer = TerminalRenderMetalLayerHandle(CAMetalLayer())
        let blitter = makeBlitter(
            executor: executor,
            backend: backend,
            releases: releases,
            layer: oldLayer
        )

        #expect(await blitter.enqueue(frame1, epoch: 1, layer: oldLayer) == .submitted)
        #expect(await blitter.enqueue(frame2, epoch: 1, layer: oldLayer) == .coalesced)

        blitter.register(epoch: 2, layer: replacementLayer)
        await backend.waitForInvalidationCount(1)

        #expect(releases.snapshot() == [TerminalRenderFrameRelease(frame: frame2)])
        #expect(backend.snapshot().cacheInvalidationCount == 1)

        backend.complete(frameSequence: 1)

        #expect(
            releases.snapshot()
                == [
                    TerminalRenderFrameRelease(frame: frame2),
                    TerminalRenderFrameRelease(frame: frame1),
                ]
        )

        blitter.register(epoch: 2, layer: TerminalRenderMetalLayerHandle(CAMetalLayer()))
        await backend.waitForInvalidationCount(2)
        blitter.stop()
        await backend.waitForInvalidationCount(3)

        #expect(backend.snapshot().cacheInvalidationCount == 3)
        #expect(releases.snapshot().count == 2)
    }

    @Test
    func replacedLayerCannotPublishLatePresentedMetadata() async throws {
        let fence = try makeFence(generation: 7)
        let frame1 = try makeFrame(fence: fence, frameSequence: 1)
        let frame2 = try makeFrame(fence: fence, frameSequence: 2)
        let executor = TerminalRenderMetalExecutor(label: "test.cmux.metal.presented-fence")
        let backend = RecordingMetalSubmissionBackend(
            executor: executor,
            results: [.submitted, .submitted]
        )
        let releases = ReleaseRecorder()
        let presented = PresentedRecorder()
        let oldLayer = TerminalRenderMetalLayerHandle(CAMetalLayer())
        let replacementLayer = TerminalRenderMetalLayerHandle(CAMetalLayer())
        let blitter = makeBlitter(
            executor: executor,
            backend: backend,
            releases: releases,
            layer: oldLayer,
            presented: presented
        )

        #expect(await blitter.enqueue(frame1, epoch: 1, layer: oldLayer) == .submitted)
        blitter.register(epoch: 1, layer: replacementLayer)
        backend.present(frameSequence: 1)
        #expect(presented.snapshot().isEmpty)

        #expect(
            await blitter.enqueue(frame2, epoch: 1, layer: replacementLayer)
                == .coalesced
        )
        backend.complete(frameSequence: 1)
        await backend.waitForSubmissionCount(2)
        backend.present(frameSequence: 2)
        #expect(presented.snapshot() == [2])
        backend.complete(frameSequence: 2)
    }

    @Test
    func newerFrameCannotBeRegressedByLatePresentedCallbackOnSameLayer() async throws {
        let fence = try makeFence(generation: 7)
        let frame1 = try makeFrame(fence: fence, frameSequence: 1)
        let frame2 = try makeFrame(fence: fence, frameSequence: 2)
        let executor = TerminalRenderMetalExecutor(
            label: "test.cmux.metal.presented-sequence-fence"
        )
        let backend = RecordingMetalSubmissionBackend(
            executor: executor,
            results: [.submitted, .submitted]
        )
        let releases = ReleaseRecorder()
        let presented = PresentedRecorder()
        let layer = TerminalRenderMetalLayerHandle(CAMetalLayer())
        let blitter = makeBlitter(
            executor: executor,
            backend: backend,
            releases: releases,
            layer: layer,
            presented: presented
        )

        #expect(await blitter.enqueue(frame1, epoch: 1, layer: layer) == .submitted)
        #expect(await blitter.enqueue(frame2, epoch: 1, layer: layer) == .coalesced)
        backend.complete(frameSequence: 1)
        await backend.waitForSubmissionCount(2)

        backend.present(frameSequence: 2)
        backend.present(frameSequence: 1)

        #expect(presented.snapshot() == [2])
        backend.complete(frameSequence: 2)
    }

    @Test
    func sourceTextureCacheUsesCompleteProvenanceKeyAndThreeEntryLRUBound() throws {
        let fence = try makeFence(generation: 7)
        let frame1 = try makeFrame(fence: fence, frameSequence: 1)
        let frame2 = try makeFrame(fence: fence, frameSequence: 2)
        let frame3 = try makeFrame(fence: fence, frameSequence: 3)
        let frame4 = try makeFrame(fence: fence, frameSequence: 4)
        let key1 = TerminalRenderMetalSourceTextureCacheKey(frame: frame1)
        let key2 = TerminalRenderMetalSourceTextureCacheKey(frame: frame2)
        let key3 = TerminalRenderMetalSourceTextureCacheKey(frame: frame3)
        let key4 = TerminalRenderMetalSourceTextureCacheKey(frame: frame4)
        let cache = TerminalRenderMetalSourceTextureCache<TestTexture>()

        #expect(key1.daemonInstanceID == fence.daemonInstanceID)
        #expect(key1.workerProcessID == frame1.workerIdentity.processID)
        #expect(key1.workerEffectiveUserID == frame1.workerIdentity.effectiveUserID)
        #expect(
            key1.workerProcessInstanceToken
                == frame1.workerIdentity.processInstanceToken
        )
        #expect(key1.rendererEpoch == fence.rendererEpoch)
        #expect(key1.presentationID == fence.presentationID)
        #expect(key1.presentationGeneration == fence.presentationGeneration)
        #expect(key1.surfaceID == frame1.surface.identifier)
        #expect(key1.width == fence.width)
        #expect(key1.height == fence.height)
        #expect(key1.pixelFormatRawValue == fence.pixelFormat.rawValue)
        #expect(cache.capacity == 3)

        let texture1 = TestTexture(id: 1)
        cache.insert(texture1, for: key1)
        cache.insert(TestTexture(id: 2), for: key2)
        cache.insert(TestTexture(id: 3), for: key3)
        #expect(cache.value(for: key1) === texture1)
        cache.insert(TestTexture(id: 4), for: key4)

        #expect(cache.count == 3)
        #expect(cache.value(for: key1) === texture1)
        #expect(cache.value(for: key2) == nil)
        cache.removeAll()
        #expect(cache.count == 0)
    }

    private func makeBlitter(
        executor: TerminalRenderMetalExecutor,
        backend: RecordingMetalSubmissionBackend,
        releases: ReleaseRecorder,
        layer: TerminalRenderMetalLayerHandle = TerminalRenderMetalLayerHandle(CAMetalLayer()),
        presented: PresentedRecorder? = nil
    ) -> TerminalRenderMetalBlitter {
        TerminalRenderMetalBlitter(
            executor: executor,
            submissionBackend: backend,
            initialEpoch: 1,
            initialLayer: layer,
            releaseHandler: { releases.append($0) },
            dispositionHandler: nil,
            metricEventHandler: nil,
            presentedHandler: { metadata in
                presented?.append(metadata.frameSequence)
            }
        )
    }

    private func makeFence(
        generation: UInt64
    ) throws -> TerminalRenderPresentationFence {
        try TerminalRenderPresentationFence(
            daemonInstanceID: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
            rendererEpoch: 3,
            terminalID: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!,
            terminalEpoch: 5,
            minimumTerminalSequence: 11,
            presentationID: UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!,
            presentationGeneration: generation,
            width: 32,
            height: 24,
            pixelFormat: .bgra8Unorm,
            colorSpace: .sRGB,
            completionRequirement: .producerCompleted
        )
    }

    private func makeFrame(
        fence: TerminalRenderPresentationFence,
        frameSequence: UInt64
    ) throws -> TerminalRenderFrame {
        let metadata = try TerminalRenderFrameMetadata(
            daemonInstanceID: fence.daemonInstanceID,
            rendererEpoch: fence.rendererEpoch,
            terminalID: fence.terminalID,
            terminalEpoch: fence.terminalEpoch,
            terminalSequence: fence.minimumTerminalSequence,
            presentationID: fence.presentationID,
            presentationGeneration: fence.presentationGeneration,
            frameSequence: frameSequence,
            width: fence.width,
            height: fence.height,
            pixelFormat: fence.pixelFormat,
            colorSpace: fence.colorSpace,
            completionFence: .producerCompleted,
            damageBounds: nil
        )
        let bytesPerElement = Int(fence.pixelFormat.bytesPerPixel)
        let bytesPerRow = Int(fence.width) * bytesPerElement
        let properties: [CFString: Any] = [
            kIOSurfaceWidth: Int(fence.width),
            kIOSurfaceHeight: Int(fence.height),
            kIOSurfaceBytesPerElement: bytesPerElement,
            kIOSurfaceBytesPerRow: bytesPerRow,
            kIOSurfaceAllocSize: bytesPerRow * Int(fence.height),
            kIOSurfacePixelFormat: fence.pixelFormat.rawValue,
        ]
        return TerminalRenderFrame(
            metadata: metadata,
            surface: TerminalRenderSurfaceHandle(
                surface: IOSurfaceCreate(properties as CFDictionary)!
            ),
            workerIdentity: try TerminalRenderWorkerIdentity(
                processID: 42,
                effectiveUserID: 501,
                processInstanceToken: TerminalRenderProcessInstanceToken(
                    startTimeSeconds: 1,
                    startTimeMicroseconds: 2
                )
            )
        )
    }
}

private final class TestTexture {
    let id: Int

    init(id: Int) {
        self.id = id
    }
}

private final class ReleaseRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var releases: [TerminalRenderFrameRelease] = []

    func append(_ release: TerminalRenderFrameRelease) {
        lock.lock()
        releases.append(release)
        lock.unlock()
    }

    func snapshot() -> [TerminalRenderFrameRelease] {
        lock.lock()
        defer { lock.unlock() }
        return releases
    }
}

private final class PresentedRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var frameSequences: [UInt64] = []

    func append(_ frameSequence: UInt64) {
        lock.lock()
        frameSequences.append(frameSequence)
        lock.unlock()
    }

    func snapshot() -> [UInt64] {
        lock.lock()
        defer { lock.unlock() }
        return frameSequences
    }
}

private final class BooleanRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue = false

    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return storedValue
    }

    func setTrue() {
        lock.lock()
        storedValue = true
        lock.unlock()
    }
}

private final class RecordingMetalSubmissionBackend:
    TerminalRenderMetalSubmitting,
    @unchecked Sendable
{
    struct Snapshot: Sendable {
        var submissionSequences: [UInt64] = []
        var commandBufferCount = 0
        var blitEncoderCount = 0
        var fullSurfaceCopyCount = 0
        var renderEncoderCount = 0
        var maximumConcurrentSubmissions = 0
        var executedOnDedicatedExecutor: [Bool] = []
        var executedOnMainThread: [Bool] = []
        var cacheInvalidationCount = 0
    }

    private let executor: TerminalRenderMetalExecutor
    private let lock = NSLock()
    private var results: [TerminalRenderMetalBackendSubmissionResult]
    private var storage = Snapshot()
    private var activeSubmissionCount = 0
    private var completions: [UInt64: @Sendable () -> Void] = [:]
    private var presentations: [UInt64: @Sendable () -> Void] = [:]
    private let submissionEvents: AsyncStream<Int>
    private let submissionContinuation: AsyncStream<Int>.Continuation
    private let invalidationEvents: AsyncStream<Int>
    private let invalidationContinuation: AsyncStream<Int>.Continuation

    init(
        executor: TerminalRenderMetalExecutor,
        results: [TerminalRenderMetalBackendSubmissionResult]
    ) {
        self.executor = executor
        self.results = results
        (submissionEvents, submissionContinuation) = AsyncStream.makeStream()
        (invalidationEvents, invalidationContinuation) = AsyncStream.makeStream()
    }

    func submitOneFullSurfaceBlit(
        frame: TerminalRenderFrame,
        layer _: TerminalRenderMetalLayerHandle,
        callbacks: TerminalRenderMetalSubmissionCallbacks
    ) -> TerminalRenderMetalBackendSubmissionResult {
        lock.lock()
        let result = results.isEmpty ? .metalUnavailable : results.removeFirst()
        storage.submissionSequences.append(frame.metadata.frameSequence)
        storage.executedOnDedicatedExecutor.append(executor.isCurrentExecutor)
        storage.executedOnMainThread.append(Thread.isMainThread)
        if result == .submitted {
            storage.commandBufferCount += 1
            storage.blitEncoderCount += 1
            storage.fullSurfaceCopyCount += 1
            activeSubmissionCount += 1
            storage.maximumConcurrentSubmissions = max(
                storage.maximumConcurrentSubmissions,
                activeSubmissionCount
            )
            completions[frame.metadata.frameSequence] = callbacks.completed
            presentations[frame.metadata.frameSequence] = callbacks.presented
        }
        let count = storage.submissionSequences.count
        lock.unlock()
        submissionContinuation.yield(count)
        return result
    }

    func invalidateSourceTextureCache() {
        lock.lock()
        storage.cacheInvalidationCount += 1
        let count = storage.cacheInvalidationCount
        lock.unlock()
        invalidationContinuation.yield(count)
    }

    func complete(frameSequence: UInt64) {
        lock.lock()
        let completion = completions.removeValue(forKey: frameSequence)
        if completion != nil {
            activeSubmissionCount -= 1
        }
        lock.unlock()
        completion?()
    }

    func present(frameSequence: UInt64) {
        lock.lock()
        let presented = presentations.removeValue(forKey: frameSequence)
        lock.unlock()
        presented?()
    }

    func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func waitForSubmissionCount(_ target: Int) async {
        if snapshot().submissionSequences.count >= target { return }
        for await count in submissionEvents where count >= target {
            return
        }
    }

    func waitForInvalidationCount(_ target: Int) async {
        if snapshot().cacheInvalidationCount >= target { return }
        for await count in invalidationEvents where count >= target {
            return
        }
    }
}
