import CMUXMobileCore
import Testing
@testable import CmuxMobileTerminalKit

@Test func retainedReplayWindowCanScrollToOldestRow() {
    var model = MobileTerminalLocalScrollbackModel()

    let metadata = model.applyMetadata(activeScreen: .primary, scrollbackRows: 2306)
    #expect(metadata?.wasAtBottom == true)

    let bounds = model.updateBounds(total: 2358, len: 52)
    #expect(bounds.maxRowOffset == 2306)
    #expect(bounds.rowOffset == 2306)
    #expect(bounds.mirrorTruncated == false)
    #expect(model.isViewingLiveBottom)

    let scroll = model.applyGesture(rowDelta: 2600)
    #expect(scroll.previousOffset == 2306)
    #expect(scroll.rowOffset == 0)
    #expect(!model.isViewingLiveBottom)
}

@Test func truncatedMirrorDoesNotPretendItCanServeReplayRows() {
    var model = MobileTerminalLocalScrollbackModel()
    _ = model.applyMetadata(activeScreen: .primary, scrollbackRows: 2306)

    let bounds = model.updateBounds(total: 1755, len: 52)

    #expect(bounds.expectedTotalRows == 2358)
    #expect(bounds.mirrorTruncated)
    #expect(bounds.maxRowOffset == 1703)
    #expect(bounds.rowOffset == 1703)
}

@Test func liveBottomAnchorsAfterReplayMetadataThenBoundsArrive() {
    var model = MobileTerminalLocalScrollbackModel()
    _ = model.updateBounds(total: 52, len: 52)

    let metadata = model.applyMetadata(activeScreen: .primary, scrollbackRows: 5154)
    #expect(metadata?.wasAtBottom == true)
    #expect(metadata?.rowOffset == 0)

    let bounds = model.updateBounds(total: 5202, len: 48)
    #expect(bounds.maxRowOffset == 5154)
    #expect(bounds.rowOffset == 5154)
    #expect(model.isViewingLiveBottom)
}

@Test func alternateScreenResetsLocalScrollbackState() {
    var model = MobileTerminalLocalScrollbackModel()
    _ = model.applyMetadata(activeScreen: .primary, scrollbackRows: 100)
    _ = model.updateBounds(total: 152, len: 52)
    _ = model.applyGesture(rowDelta: 10)

    _ = model.applyMetadata(activeScreen: .alternate, scrollbackRows: 0)
    let bounds = model.updateBounds(total: 52, len: 52)

    #expect(bounds.maxRowOffset == 0)
    #expect(bounds.rowOffset == 0)
    #expect(model.replayScrollbackRows == 0)
    #expect(model.isViewingLiveBottom)
}
