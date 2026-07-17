import Foundation
import Testing
@testable import CmuxTerminalRenderer

struct RendererFrameAcceptanceTests {
    private let workspaceID = UUID()
    private let surfaceID = UUID()

    @Test
    func acceptsFirstFrameFromCurrentGeneration() {
        let frame = makeFrame(generation: 7, sequence: 1)

        #expect(RendererFrameAcceptance.accepts(
            frame,
            currentGeneration: 7,
            lastAccepted: nil
        ))
    }

    @Test
    func rejectsDelayedFrameFromReplacedWorker() {
        let frame = makeFrame(generation: 6, sequence: 900)

        #expect(!RendererFrameAcceptance.accepts(
            frame,
            currentGeneration: 7,
            lastAccepted: makeFrame(generation: 7, sequence: 2)
        ))
    }

    @Test(arguments: [8, 9])
    func rejectsDuplicateAndOlderFrames(sequence: UInt64) {
        let frame = makeFrame(generation: 7, sequence: sequence)

        #expect(!RendererFrameAcceptance.accepts(
            frame,
            currentGeneration: 7,
            lastAccepted: makeFrame(generation: 7, sequence: 9)
        ))
    }

    @Test
    func acceptsFirstFrameFromReplacementGeneration() {
        let frame = makeFrame(generation: 8, sequence: 1)

        #expect(RendererFrameAcceptance.accepts(
            frame,
            currentGeneration: 8,
            lastAccepted: makeFrame(generation: 7, sequence: 900)
        ))
    }

    private func makeFrame(generation: UInt64, sequence: UInt64) -> RendererFrameMetadata {
        RendererFrameMetadata(
            identity: RendererSurfaceIdentity(
                workspaceID: workspaceID,
                surfaceID: surfaceID,
                generation: generation
            ),
            sequence: sequence,
            pixelWidth: 1200,
            pixelHeight: 800,
            scaleX: 2,
            scaleY: 2
        )
    }
}
