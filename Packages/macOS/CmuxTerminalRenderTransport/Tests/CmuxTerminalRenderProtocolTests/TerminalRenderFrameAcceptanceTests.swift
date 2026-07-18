import Foundation
import Testing
@testable import CmuxTerminalRenderProtocol

@Suite
struct TerminalRenderFrameAcceptanceTests {
    private let fixture = TerminalRenderProtocolTestFixture()

    @Test
    func acceptsCurrentMetadataAndRejectsDuplicateOrOlderFrames() throws {
        let fence = try fixture.makeFence()
        var acceptance = TerminalRenderFrameAcceptance()

        #expect(acceptance.accept(try fixture.makeMetadata(frameSequence: 10), against: fence) == nil)
        #expect(
            acceptance.accept(try fixture.makeMetadata(frameSequence: 10), against: fence)
                == .staleFrameSequence
        )
        #expect(
            acceptance.accept(try fixture.makeMetadata(frameSequence: 9), against: fence)
                == .staleFrameSequence
        )
        #expect(acceptance.lastFrameSequence == 10)
    }

    @Test
    func rejectsEveryIdentityGenerationAndPresentationMismatch() throws {
        let fence = try fixture.makeFence()
        let anotherID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!

        let cases: [(TerminalRenderFrameMetadata, TerminalRenderFrameRejection)] = [
            (try fixture.makeMetadata(daemonInstanceID: anotherID), .daemonInstanceMismatch),
            (try fixture.makeMetadata(rendererEpoch: 8), .rendererEpochMismatch),
            (try fixture.makeMetadata(terminalID: anotherID), .terminalIdentityMismatch),
            (try fixture.makeMetadata(terminalEpoch: 12), .terminalEpochMismatch),
            (try fixture.makeMetadata(terminalSequence: 89), .staleTerminalSequence),
            (try fixture.makeMetadata(presentationID: anotherID), .presentationIdentityMismatch),
            (try fixture.makeMetadata(presentationGeneration: 14), .presentationGenerationMismatch),
            (try fixture.makeMetadata(width: 1_599), .dimensionsMismatch),
            (try fixture.makeMetadata(pixelFormat: .rgba16Float), .pixelFormatMismatch),
            (try fixture.makeMetadata(colorSpace: .sRGB), .colorSpaceMismatch),
            (
                try fixture.makeMetadata(completionFenceEventID: anotherID),
                .completionFenceIdentityMismatch
            ),
            (try fixture.makeMetadata(completionFenceValue: 9), .staleCompletionFence),
        ]

        for (metadata, expected) in cases {
            var acceptance = TerminalRenderFrameAcceptance()
            #expect(acceptance.accept(metadata, against: fence) == expected)
            #expect(acceptance.lastFrameSequence == nil)
        }
    }

    @Test
    func acceptsProducerCompletedFramesAndRejectsCompletionModeChanges() throws {
        let producerFence = try fixture.makeFence(producerCompleted: true)
        var producerAcceptance = TerminalRenderFrameAcceptance()
        #expect(producerAcceptance.accept(
            try fixture.makeMetadata(producerCompleted: true),
            against: producerFence
        ) == nil)
        #expect(producerAcceptance.lastCompletionFenceValue == nil)

        var sharedAcceptance = TerminalRenderFrameAcceptance()
        #expect(sharedAcceptance.accept(
            try fixture.makeMetadata(producerCompleted: true),
            against: try fixture.makeFence()
        ) == .completionModeMismatch)
        #expect(sharedAcceptance.accept(
            try fixture.makeMetadata(),
            against: producerFence
        ) == .completionModeMismatch)
    }

    @Test
    func rejectsTerminalAndCompletionRegressionsAfterNewerFrame() throws {
        let fence = try fixture.makeFence()
        var acceptance = TerminalRenderFrameAcceptance()
        #expect(acceptance.accept(
            try fixture.makeMetadata(
                terminalSequence: 200,
                frameSequence: 200,
                completionFenceValue: 200
            ),
            against: fence
        ) == nil)

        #expect(acceptance.accept(
            try fixture.makeMetadata(
                terminalSequence: 199,
                frameSequence: 201,
                completionFenceValue: 201
            ),
            against: fence
        ) == .staleTerminalSequence)
        #expect(acceptance.accept(
            try fixture.makeMetadata(
                terminalSequence: 201,
                frameSequence: 201,
                completionFenceValue: 199
            ),
            against: fence
        ) == .staleCompletionFence)
    }

    @Test
    func sequenceWrapRequiresANewEpochOrGeneration() throws {
        let fence = try fixture.makeFence(minimumTerminalSequence: UInt64.max - 1)
        var acceptance = TerminalRenderFrameAcceptance()

        #expect(acceptance.accept(
            try fixture.makeMetadata(
                terminalSequence: UInt64.max - 1,
                frameSequence: UInt64.max - 1
            ),
            against: fence
        ) == nil)
        #expect(acceptance.accept(
            try fixture.makeMetadata(
                terminalSequence: UInt64.max,
                frameSequence: UInt64.max,
                completionFenceValue: 20
            ),
            against: fence
        ) == nil)
        #expect(acceptance.accept(
            try fixture.makeMetadata(
                terminalSequence: 0,
                frameSequence: 0,
                completionFenceValue: 21
            ),
            against: fence
        ) == .staleTerminalSequence)
        #expect(acceptance.lastFrameSequence == UInt64.max)
    }

    @Test
    func failedCandidateDoesNotAdvanceAcceptanceState() throws {
        let fence = try fixture.makeFence()
        var acceptance = TerminalRenderFrameAcceptance()
        #expect(acceptance.accept(try fixture.makeMetadata(frameSequence: 50), against: fence) == nil)

        #expect(acceptance.accept(
            try fixture.makeMetadata(presentationGeneration: 999, frameSequence: 500),
            against: fence
        ) == .presentationGenerationMismatch)
        #expect(acceptance.lastFrameSequence == 50)
        #expect(acceptance.accept(try fixture.makeMetadata(frameSequence: 51), against: fence) == nil)
    }
}
