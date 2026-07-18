import CoreFoundation
import Foundation
import IOSurface
import Testing
@testable import CmuxTerminalRenderCompositor
@testable import CmuxTerminalRenderProtocol
@testable import CmuxTerminalRenderTransport

struct TerminalRenderCompositorViewTests {
    @Test
    @MainActor
    func metadataRejectionReleasesTheExactWorkerLease() async throws {
        let fence = try makeFence(generation: 7)
        let (releases, continuation) = AsyncStream<TerminalRenderFrameRelease>.makeStream()
        let view = try TerminalRenderCompositorView(fence: fence) {
            continuation.yield($0)
        }
        let stale = try makeFrame(fence: fence, generation: 6, frameSequence: 4)

        let result = await view.enqueue(stale)

        #expect(result == .rejected(.presentationGenerationMismatch))
        var iterator = releases.makeAsyncIterator()
        let release = await iterator.next()
        #expect(release == TerminalRenderFrameRelease(frame: stale))
        continuation.finish()
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
                effectiveUserID: 501
            )
        )
    }
}
