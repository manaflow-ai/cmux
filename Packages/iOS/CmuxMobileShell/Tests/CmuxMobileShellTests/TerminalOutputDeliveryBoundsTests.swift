import CMUXMobileCore
import Foundation
import Testing
@testable import CmuxMobileShell

@MainActor
@Test func terminalOutputDeliveryUsesPreparedRenderGridBytes() throws {
    let frame = try makeBoundsTestFrame()
    let preparedBytes = Data("prepared-off-main".utf8)

    let delivery = TerminalOutputDelivery(
        renderGrid: frame,
        preparedBytes: preparedBytes,
        replaceable: false
    )

    #expect(delivery.bytes == preparedBytes)
    #expect(delivery.retainedOutputByteCount == preparedBytes.count)
}

@MainActor
@Test func terminalOutputQueueBoundsSeparatedRenderGridFrames() throws {
    var queue = TerminalOutputDeliveryQueue()
    let frame = try makeBoundsTestFrame()

    for index in 0..<TerminalOutputDeliveryQueue.maximumRetainedRenderGridCount {
        let delivery = TerminalOutputDelivery(
            renderGrid: frame,
            preparedBytes: Data([UInt8(index)]),
            replaceable: false
        )
        _ = queue.enqueue(delivery)
    }
    let overflow = TerminalOutputDelivery(
        renderGrid: frame,
        preparedBytes: Data([0xFF]),
        replaceable: false
    )

    #expect(queue.enqueue(overflow) == nil)
    let didOverflow = queue.consumeOutputBacklogOverflow()
    #expect(didOverflow)
    #expect(queue.pendingCount == TerminalOutputDeliveryQueue.maximumRetainedRenderGridCount - 1)
}

@MainActor
@Test func terminalOutputQueueBoundsRetainedRenderGridBytes() throws {
    var queue = TerminalOutputDeliveryQueue()
    let frame = try makeBoundsTestFrame()
    let atLimit = TerminalOutputDelivery(
        renderGrid: frame,
        preparedBytes: Data(
            repeating: 0x41,
            count: TerminalOutputDeliveryQueue.maximumRetainedOutputByteCount
        ),
        replaceable: false
    )

    #expect(queue.enqueue(atLimit) == atLimit)
    let overflow = TerminalOutputDelivery(
        renderGrid: frame,
        preparedBytes: Data([0x42]),
        replaceable: false
    )
    #expect(queue.enqueue(overflow) == nil)
    let didOverflow = queue.consumeOutputBacklogOverflow()
    #expect(didOverflow)
    #expect(queue.pendingCount == 0)
}

private func makeBoundsTestFrame() throws -> MobileTerminalRenderGridFrame {
    try MobileTerminalRenderGridFrame.fromPlainRows(
        surfaceID: "terminal",
        stateSeq: 1,
        columns: 12,
        rows: 1,
        text: "frame"
    )
}
