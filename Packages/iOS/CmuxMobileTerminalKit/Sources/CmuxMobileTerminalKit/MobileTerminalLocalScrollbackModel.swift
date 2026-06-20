public import CMUXMobileCore
import Foundation

/// Value model for the phone-local primary-screen scrollback mirror.
///
/// The Mac owns terminal history and sends a bounded render-grid replay. The
/// iOS Ghostty surface is only a local mirror of that window, so scroll range
/// is derived from replay metadata plus Ghostty retention observations in one
/// place instead of scattered UIKit fields.
public struct MobileTerminalLocalScrollbackModel: Equatable, Sendable {
    public struct BoundsResult: Equatable, Sendable {
        public let rowOffset: Double
        public let maxRowOffset: Double
        public let wasAtBottom: Bool
        public let expectedTotalRows: UInt64
        public let mirrorTruncated: Bool
    }

    public struct MetadataResult: Equatable, Sendable {
        public let rowOffset: Double
        public let maxRowOffset: Double
        public let wasAtBottom: Bool
    }

    public struct ScrollResult: Equatable, Sendable {
        public let previousOffset: Double
        public let rowOffset: Double
        public let maxRowOffset: Double
    }

    public private(set) var activeScreen: MobileTerminalRenderGridFrame.Screen = .primary
    public private(set) var rowOffset: Double = 0
    public private(set) var maxRowOffset: Double = 0
    public private(set) var replayScrollbackRows: Int = 0
    public private(set) var visibleRows: UInt64 = 0
    public private(set) var observedTotalRows: UInt64 = 0
    public private(set) var mirrorTruncated = false

    private var boundsInitialized = false
    private var anchorToBottomOnNextBounds = false

    public init() {}

    public var isViewingLiveBottom: Bool {
        activeScreen != .primary || maxRowOffset <= 0 || abs(rowOffset - maxRowOffset) < 0.5
    }

    public mutating func applyMetadata(
        activeScreen: MobileTerminalRenderGridFrame.Screen?,
        scrollbackRows: Int?
    ) -> MetadataResult? {
        if let activeScreen {
            self.activeScreen = activeScreen
        }
        guard let scrollbackRows else { return nil }

        let wasAtBottom = !boundsInitialized || abs(rowOffset - maxRowOffset) < 0.5
        anchorToBottomOnNextBounds = wasAtBottom
        replayScrollbackRows = max(0, scrollbackRows)
        if wasAtBottom, boundsInitialized {
            rowOffset = maxRowOffset
        }
        return MetadataResult(
            rowOffset: rowOffset,
            maxRowOffset: maxRowOffset,
            wasAtBottom: wasAtBottom
        )
    }

    public mutating func updateBounds(total: UInt64, len: UInt64) -> BoundsResult {
        guard activeScreen == .primary else {
            resetForNonPrimaryScreen()
            return BoundsResult(
                rowOffset: rowOffset,
                maxRowOffset: maxRowOffset,
                wasAtBottom: true,
                expectedTotalRows: 0,
                mirrorTruncated: false
            )
        }

        observedTotalRows = total
        visibleRows = len
        let observedMax = total > len ? Double(total - len) : 0
        let expectedTotal = UInt64(max(0, replayScrollbackRows)) + len
        mirrorTruncated = replayScrollbackRows > 0 && total + 1 < expectedTotal
        let nextMax = mirrorTruncated ? observedMax : max(observedMax, Double(replayScrollbackRows))
        let previousMax = maxRowOffset
        let wasAtBottom = !boundsInitialized
            || anchorToBottomOnNextBounds
            || abs(rowOffset - previousMax) < 0.5

        maxRowOffset = nextMax
        boundsInitialized = true
        if wasAtBottom || rowOffset > nextMax {
            rowOffset = nextMax
        }
        anchorToBottomOnNextBounds = false

        return BoundsResult(
            rowOffset: rowOffset,
            maxRowOffset: maxRowOffset,
            wasAtBottom: wasAtBottom,
            expectedTotalRows: expectedTotal,
            mirrorTruncated: mirrorTruncated
        )
    }

    public mutating func applyGesture(rowDelta: Double) -> ScrollResult {
        let previous = rowOffset
        rowOffset = min(max(rowOffset - rowDelta, 0), maxRowOffset)
        return ScrollResult(
            previousOffset: previous,
            rowOffset: rowOffset,
            maxRowOffset: maxRowOffset
        )
    }

    private mutating func resetForNonPrimaryScreen() {
        rowOffset = 0
        maxRowOffset = 0
        replayScrollbackRows = 0
        visibleRows = 0
        observedTotalRows = 0
        mirrorTruncated = false
        boundsInitialized = false
        anchorToBottomOnNextBounds = false
    }
}
