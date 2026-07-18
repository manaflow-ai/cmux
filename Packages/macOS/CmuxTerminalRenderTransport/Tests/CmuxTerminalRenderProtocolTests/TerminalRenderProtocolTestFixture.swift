import Foundation
@testable import CmuxTerminalRenderProtocol

struct TerminalRenderProtocolTestFixture {
    let daemonInstanceID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    let terminalID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    let presentationID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
    let completionFenceEventID = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!

    func makeMetadata(
        daemonInstanceID: UUID? = nil,
        rendererEpoch: UInt64 = 7,
        terminalID: UUID? = nil,
        terminalEpoch: UInt64 = 11,
        terminalSequence: UInt64 = 100,
        presentationID: UUID? = nil,
        presentationGeneration: UInt64 = 13,
        frameSequence: UInt64 = 17,
        width: UInt32 = 1_600,
        height: UInt32 = 900,
        pixelFormat: TerminalRenderPixelFormat = .bgra8Unorm,
        colorSpace: TerminalRenderColorSpace = .displayP3,
        producerCompleted: Bool = false,
        completionFenceEventID: UUID? = nil,
        completionFenceValue: UInt64 = 19,
        damageBounds: TerminalRenderDamageBounds? = nil
    ) throws -> TerminalRenderFrameMetadata {
        try TerminalRenderFrameMetadata(
            daemonInstanceID: daemonInstanceID ?? self.daemonInstanceID,
            rendererEpoch: rendererEpoch,
            terminalID: terminalID ?? self.terminalID,
            terminalEpoch: terminalEpoch,
            terminalSequence: terminalSequence,
            presentationID: presentationID ?? self.presentationID,
            presentationGeneration: presentationGeneration,
            frameSequence: frameSequence,
            width: width,
            height: height,
            pixelFormat: pixelFormat,
            colorSpace: colorSpace,
            completionFence: producerCompleted
                ? .producerCompleted
                : .sharedEvent(
                    eventID: completionFenceEventID ?? self.completionFenceEventID,
                    value: completionFenceValue
                ),
            damageBounds: damageBounds
        )
    }

    func makeFence(
        daemonInstanceID: UUID? = nil,
        rendererEpoch: UInt64 = 7,
        terminalID: UUID? = nil,
        terminalEpoch: UInt64 = 11,
        minimumTerminalSequence: UInt64 = 90,
        presentationID: UUID? = nil,
        presentationGeneration: UInt64 = 13,
        width: UInt32 = 1_600,
        height: UInt32 = 900,
        pixelFormat: TerminalRenderPixelFormat = .bgra8Unorm,
        colorSpace: TerminalRenderColorSpace = .displayP3,
        producerCompleted: Bool = false,
        completionFenceEventID: UUID? = nil,
        minimumCompletionFenceValue: UInt64 = 10
    ) throws -> TerminalRenderPresentationFence {
        try TerminalRenderPresentationFence(
            daemonInstanceID: daemonInstanceID ?? self.daemonInstanceID,
            rendererEpoch: rendererEpoch,
            terminalID: terminalID ?? self.terminalID,
            terminalEpoch: terminalEpoch,
            minimumTerminalSequence: minimumTerminalSequence,
            presentationID: presentationID ?? self.presentationID,
            presentationGeneration: presentationGeneration,
            width: width,
            height: height,
            pixelFormat: pixelFormat,
            colorSpace: colorSpace,
            completionRequirement: producerCompleted
                ? .producerCompleted
                : .sharedEvent(
                    eventID: completionFenceEventID ?? self.completionFenceEventID,
                    minimumValue: minimumCompletionFenceValue
                )
        )
    }
}
