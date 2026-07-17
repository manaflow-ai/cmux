import CoreFoundation
import IOSurface
import QuartzCore
import Testing
@testable import CmuxTerminal
import CmuxTerminalRenderTransport

@Suite(.serialized)
@MainActor
struct GhosttyRemoteIOSurfaceLayerTests {
    private let surfaceID = UUID(uuidString: "184DCEB4-F88C-4A9D-89F4-03087E606B8B")!
    private let pixelSize = GhosttyRenderPixelSize(width: 32, height: 24)

    @Test func acceptsMatchingFrameAndConfiguresPixelPresentation() throws {
        let layer = makeLayer(backingScaleFactor: 2)
        let frame = try makeFrame(sequence: 7)

        #expect(layer.present(frame))
        #expect(layer.lastAcceptedFrameSequence == 7)
        #expect(layer.contentsGravity == .topLeft)
        #expect(layer.contentsScale == 2)
        #expect(layer.retainedSurface.map(IOSurfaceGetID) == IOSurfaceGetID(frame.surface))
        #expect(displayedSurfaceID(layer) == IOSurfaceGetID(frame.surface))
    }

    @Test func rejectsWrongSurfaceIdentityWithoutReplacingContents() throws {
        let layer = makeLayer()
        let accepted = try makeFrame(sequence: 1)
        #expect(layer.present(accepted))
        let retainedID = IOSurfaceGetID(accepted.surface)

        let rejected = try makeFrame(surfaceID: UUID(), sequence: 2)
        #expect(!layer.present(rejected))
        expectRetainsSurface(layer, id: retainedID, sequence: 1)
    }

    @Test func fencesWorkerGenerationAndRejectsLateFramesAfterExit() throws {
        let layer = makeLayer()
        let accepted = try makeFrame(sequence: 5)
        #expect(layer.present(accepted))
        let retainedID = IOSurfaceGetID(accepted.surface)

        let wrongWorker = try makeFrame(workerGeneration: 12, sequence: 6)
        #expect(!layer.present(wrongWorker))
        layer.invalidateWorkerGeneration(11)
        #expect(layer.workerGeneration == nil)
        #expect(!layer.present(try makeFrame(sequence: 7)))
        expectRetainsSurface(layer, id: retainedID, sequence: nil)

        layer.updateWorkerGeneration(12)
        #expect(layer.present(try makeFrame(workerGeneration: 12, sequence: 0)))
    }

    @Test func staleWorkerExitCannotInvalidateNewWorker() {
        let layer = makeLayer()
        layer.updateWorkerGeneration(12)
        layer.invalidateWorkerGeneration(11)
        #expect(layer.workerGeneration == 12)
    }

    @Test func fencesSurfaceGenerationAndAllowsNewSequenceAfterReconfiguration() throws {
        let layer = makeLayer()
        let accepted = try makeFrame(sequence: 9)
        #expect(layer.present(accepted))
        let retainedID = IOSurfaceGetID(accepted.surface)

        #expect(!layer.present(try makeFrame(surfaceGeneration: 4, sequence: 10)))
        layer.updateSurfaceGeneration(4)
        expectRetainsSurface(layer, id: retainedID, sequence: nil)
        #expect(layer.present(try makeFrame(surfaceGeneration: 4, sequence: 0)))
    }

    @Test func rejectsDuplicateAndDecreasingFrameSequences() throws {
        let layer = makeLayer()
        let accepted = try makeFrame(sequence: 8)
        #expect(layer.present(accepted))
        let retainedID = IOSurfaceGetID(accepted.surface)

        #expect(!layer.present(try makeFrame(sequence: 8)))
        #expect(!layer.present(try makeFrame(sequence: 7)))
        expectRetainsSurface(layer, id: retainedID, sequence: 8)
        #expect(layer.present(try makeFrame(sequence: 9)))
    }

    @Test func rejectsMetadataWidthThatDoesNotMatchIOSurface() throws {
        let layer = makeLayer()
        let rejected = try makeFrame(
            metadataSize: GhosttyRenderPixelSize(width: 31, height: 24),
            surfaceSize: pixelSize
        )

        #expect(!layer.present(rejected))
        #expect(layer.contents == nil)
        #expect(layer.retainedSurface == nil)
    }

    @Test func rejectsMetadataHeightThatDoesNotMatchIOSurface() throws {
        let layer = makeLayer()
        let rejected = try makeFrame(
            metadataSize: pixelSize,
            surfaceSize: GhosttyRenderPixelSize(width: 32, height: 23)
        )

        #expect(!layer.present(rejected))
        #expect(layer.contents == nil)
        #expect(layer.retainedSurface == nil)
    }

    @Test func liveResizeAcceptsNewerConsistentFrameAtPreviouslyRenderedSize() throws {
        let layer = makeLayer()
        let accepted = try makeFrame(sequence: 3)
        #expect(layer.present(accepted))

        let newSize = GhosttyRenderPixelSize(width: 48, height: 40)
        layer.updateExpectedPixelSize(newSize)
        layer.updateBackingScaleFactor(3)
        #expect(layer.contentsScale == 3)

        let newerFrameAtPreviousSize = try makeFrame(sequence: 4)
        try #require(layer.present(newerFrameAtPreviousSize))
        expectRetainsSurface(
            layer,
            id: IOSurfaceGetID(newerFrameAtPreviousSize.surface),
            sequence: 4
        )

        #expect(layer.present(try makeFrame(sequence: 5, metadataSize: newSize, surfaceSize: newSize)))
    }

    private func makeLayer(backingScaleFactor: CGFloat = 1) -> GhosttyRemoteIOSurfaceLayer {
        GhosttyRemoteIOSurfaceLayer(
            surfaceID: surfaceID,
            workerGeneration: 11,
            surfaceGeneration: 3,
            expectedPixelSize: pixelSize,
            backingScaleFactor: backingScaleFactor
        )
    }

    private func makeFrame(
        surfaceID: UUID? = nil,
        workerGeneration: UInt64 = 11,
        surfaceGeneration: UInt64 = 3,
        sequence: UInt64 = 1,
        metadataSize: GhosttyRenderPixelSize? = nil,
        surfaceSize: GhosttyRenderPixelSize? = nil
    ) throws -> TerminalRenderFrame {
        let metadataSize = metadataSize ?? pixelSize
        let surfaceSize = surfaceSize ?? metadataSize
        let receiver = try TerminalRenderFrameReceiver()
        let sender = try TerminalRenderFrameSender(endpoint: receiver.endpoint)
        let surface = makeIOSurface(size: surfaceSize)
        let metadata = TerminalRenderFrameMetadata(
            surfaceID: surfaceID ?? self.surfaceID,
            workerGeneration: workerGeneration,
            surfaceGeneration: surfaceGeneration,
            frameSequence: sequence,
            width: metadataSize.width,
            height: metadataSize.height
        )

        #expect(try sender.send(surface: surface, metadata: metadata))
        let received = try receiver.receiveOne(timeoutMilliseconds: 1_000)
        return try #require(received)
    }

    private func makeIOSurface(size: GhosttyRenderPixelSize) -> IOSurfaceRef {
        let width = Int(size.width)
        let height = Int(size.height)
        let bytesPerRow = width * 4
        let properties: [CFString: Any] = [
            kIOSurfaceWidth: width,
            kIOSurfaceHeight: height,
            kIOSurfaceBytesPerElement: 4,
            kIOSurfaceBytesPerRow: bytesPerRow,
            kIOSurfaceAllocSize: bytesPerRow * height,
        ]
        return IOSurfaceCreate(properties as CFDictionary)!
    }

    private func expectRetainsSurface(
        _ layer: GhosttyRemoteIOSurfaceLayer,
        id: IOSurfaceID,
        sequence: UInt64?
    ) {
        #expect(layer.retainedSurface.map(IOSurfaceGetID) == id)
        #expect(displayedSurfaceID(layer) == id)
        #expect(layer.lastAcceptedFrameSequence == sequence)
    }

    private func displayedSurfaceID(_ layer: CALayer) -> IOSurfaceID? {
        guard let contents = layer.contents else { return nil }
        let coreFoundationContents = contents as CFTypeRef
        guard CFGetTypeID(coreFoundationContents) == IOSurfaceGetTypeID() else { return nil }
        return IOSurfaceGetID(contents as! IOSurfaceRef)
    }
}
