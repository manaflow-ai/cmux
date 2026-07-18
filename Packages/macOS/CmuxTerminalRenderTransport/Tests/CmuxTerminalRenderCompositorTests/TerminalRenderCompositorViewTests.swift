import CoreFoundation
import Foundation
import IOSurface
import QuartzCore
import Testing
@testable import CmuxTerminalRenderCompositor
@testable import CmuxTerminalRenderProtocol
@testable import CmuxTerminalRenderTransport

struct TerminalRenderCompositorViewTests {
    @Test
    @MainActor
    func drawableTexturePermitsTheSingleHostBlit() throws {
        let view = try TerminalRenderCompositorView(
            fence: makeFence(generation: 1),
            frameReleaseHandler: { _ in }
        )

        let layer = try #require(view.layer as? CAMetalLayer)
        #expect(layer.framebufferOnly == false)
    }

    @Test
    @MainActor
    func retiredCompositorRejectsAndReleasesQueuedPriorPlacementFrame() async throws {
        let fence = try makeFence(generation: 7)
        let (releases, continuation) = AsyncStream<TerminalRenderFrameRelease>.makeStream()
        let view = try TerminalRenderCompositorView(
            fence: fence,
            frameReleaseHandler: { continuation.yield($0) }
        )
        let frame = try makeFrame(fence: fence, generation: 7, frameSequence: 9)

        view.retire()
        let result = await view.enqueue(frame)

        #expect(result == .rejected(.presentationGenerationMismatch))
        var iterator = releases.makeAsyncIterator()
        #expect(await iterator.next() == TerminalRenderFrameRelease(frame: frame))
        continuation.finish()
    }

    @Test
    @MainActor
    func metadataRejectionReleasesTheExactWorkerLease() async throws {
        let fence = try makeFence(generation: 7)
        let (releases, continuation) = AsyncStream<TerminalRenderFrameRelease>.makeStream()
        let workspaceID = UUID(uuidString: "DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD")!
        let provenance = TerminalRenderFrameProvenanceBuffer(capacity: 2)
        let aggregateMetrics = TerminalRenderCompositorMetricsRecorder()
        let view = try TerminalRenderCompositorView(
            fence: fence,
            frameReleaseHandler: { continuation.yield($0) },
            frameDispositionHandler: { frame, result in
                provenance.append(TerminalRenderFrameProvenanceRecord(
                    monotonicNanoseconds: 123,
                    workspaceID: workspaceID,
                    frame: frame,
                    result: result
                ))
            },
            metricEventHandler: { aggregateMetrics.record($0) }
        )
        let stale = try makeFrame(fence: fence, generation: 6, frameSequence: 4)

        let result = await view.enqueue(stale)

        #expect(result == .rejected(.presentationGenerationMismatch))
        var iterator = releases.makeAsyncIterator()
        let release = await iterator.next()
        #expect(release == TerminalRenderFrameRelease(frame: stale))
        let metrics = await view.metricsSnapshot()
        #expect(metrics.receivedFrames == 1)
        #expect(metrics.admittedFrames == 0)
        #expect(metrics.rejectedFrames == 1)
        #expect(metrics.submittedBlits == 0)
        #expect(metrics.coalescedFrames == 0)
        #expect(metrics.drawableUnavailableEvents == 0)
        #expect(metrics.metalUnavailableFrames == 0)
        #expect(aggregateMetrics.snapshot() == metrics)
        let provenanceSnapshot = provenance.snapshot()
        #expect(provenanceSnapshot.totalRecordCount == 1)
        #expect(provenanceSnapshot.droppedRecordCount == 0)
        #expect(provenanceSnapshot.records.first?.rejectionReason
            == "presentation_generation_mismatch")
        continuation.finish()
    }

    @Test
    @MainActor
    func sendableIngressAdmitsFramesWithoutEnteringTheMainActor() async throws {
        let fence = try makeFence(generation: 7)
        let (releases, continuation) = AsyncStream<TerminalRenderFrameRelease>.makeStream()
        let view = try TerminalRenderCompositorView(
            fence: fence,
            frameReleaseHandler: { continuation.yield($0) }
        )
        let stale = try makeFrame(fence: fence, generation: 6, frameSequence: 4)
        let ingress = view.frameIngress

        let result = await Task.detached {
            await ingress.enqueue(stale)
        }.value

        #expect(result == .rejected(.presentationGenerationMismatch))
        var iterator = releases.makeAsyncIterator()
        #expect(await iterator.next() == TerminalRenderFrameRelease(frame: stale))
        let metrics = await ingress.metricsSnapshot()
        #expect(metrics.receivedFrames == 1)
        #expect(metrics.admittedFrames == 0)
        #expect(metrics.rejectedFrames == 1)
        continuation.finish()
    }

    @Test
    @MainActor
    func provenanceBindsAuditIdentityFencesSurfaceAndDisposition() async throws {
        let fence = try makeFence(generation: 7)
        let frame = try makeFrame(fence: fence, generation: 6, frameSequence: 4)
        let result = TerminalRenderCompositorEnqueueResult.rejected(
            .presentationGenerationMismatch
        )
        let workspaceID = UUID(uuidString: "DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD")!
        let record = TerminalRenderFrameProvenanceRecord(
            monotonicNanoseconds: 123,
            workspaceID: workspaceID,
            frame: frame,
            result: result
        )

        #expect(record.workerProcessID == 42)
        #expect(record.workerEffectiveUserID == 501)
        #expect(record.daemonInstanceID == fence.daemonInstanceID)
        #expect(record.workspaceID == workspaceID)
        #expect(record.terminalID == fence.terminalID)
        #expect(record.rendererEpoch == fence.rendererEpoch)
        #expect(record.presentationID == fence.presentationID)
        #expect(record.presentationGeneration == 6)
        #expect(record.frameSequence == 4)
        #expect(record.surfaceID == frame.surface.identifier)
        #expect(record.disposition == .rejected)
        #expect(record.rejectionReason == "presentation_generation_mismatch")

        let buffer = TerminalRenderFrameProvenanceBuffer(capacity: 1)
        buffer.append(record)
        buffer.append(record)
        let snapshot = buffer.snapshot()
        #expect(snapshot.totalRecordCount == 2)
        #expect(snapshot.droppedRecordCount == 1)
        #expect(snapshot.records == [record])

        let prior = buffer.snapshotAndReset()
        #expect(prior == snapshot)
        #expect(buffer.snapshot() == TerminalRenderFrameProvenanceSnapshot(
            totalRecordCount: 0,
            droppedRecordCount: 0,
            records: []
        ))

        let encoded = try JSONEncoder().encode(snapshot)
        #expect(try JSONDecoder().decode(
            TerminalRenderFrameProvenanceSnapshot.self,
            from: encoded
        ) == snapshot)
    }

    @Test
    func aggregateMetricRecorderSnapshotsAndResetsAtomically() {
        let recorder = TerminalRenderCompositorMetricsRecorder()
        recorder.record(.receivedFrame)
        recorder.record(.admittedFrame)
        recorder.record(.submittedBlit)
        recorder.record(.coalescedFrame)
        recorder.record(.rejectedFrame)
        recorder.record(.drawableUnavailable)
        recorder.record(.metalUnavailable)

        let prior = recorder.snapshotAndReset()
        #expect(prior.receivedFrames == 1)
        #expect(prior.admittedFrames == 1)
        #expect(prior.submittedBlits == 1)
        #expect(prior.coalescedFrames == 1)
        #expect(prior.rejectedFrames == 1)
        #expect(prior.drawableUnavailableEvents == 1)
        #expect(prior.metalUnavailableFrames == 1)
        #expect(recorder.snapshot() == TerminalRenderCompositorMetrics())
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
        generation: UInt64,
        frameSequence: UInt64
    ) throws -> TerminalRenderFrame {
        let metadata = try TerminalRenderFrameMetadata(
            daemonInstanceID: fence.daemonInstanceID,
            rendererEpoch: fence.rendererEpoch,
            terminalID: fence.terminalID,
            terminalEpoch: fence.terminalEpoch,
            terminalSequence: fence.minimumTerminalSequence,
            presentationID: fence.presentationID,
            presentationGeneration: generation,
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
        let surface = TerminalRenderSurfaceHandle(
            surface: IOSurfaceCreate(properties as CFDictionary)!
        )
        return TerminalRenderFrame(
            metadata: metadata,
            surface: surface,
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
