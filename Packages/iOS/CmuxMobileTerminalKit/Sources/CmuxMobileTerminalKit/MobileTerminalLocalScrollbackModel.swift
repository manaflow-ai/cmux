public import CMUXMobileCore
import Foundation

/// Value model for the phone-local primary-screen scrollback mirror.
///
/// The Mac owns terminal history and sends a bounded render-grid replay. The
/// iOS Ghostty surface is only a local mirror of that window, so scroll range
/// is derived from replay metadata plus Ghostty retention observations in one
/// place instead of scattered UIKit fields.
public struct MobileTerminalLocalScrollbackModel: Equatable, Sendable {
    public struct BottomAnchorPolicy: Equatable, Sendable {
        public let toleranceRows: Double

        public init(toleranceRows: Double = 0.5) {
            self.toleranceRows = max(0, toleranceRows)
        }

        public func isAtBottom(offset: Double, maxOffset: Double) -> Bool {
            maxOffset <= 0 || abs(offset - maxOffset) < toleranceRows
        }
    }

    public struct ReplayWindow: Equatable, Sendable {
        public let activeScreen: MobileTerminalRenderGridFrame.Screen
        public let scrollbackRows: Int

        public init(
            activeScreen: MobileTerminalRenderGridFrame.Screen = .primary,
            scrollbackRows: Int = 0
        ) {
            self.activeScreen = activeScreen
            self.scrollbackRows = max(0, scrollbackRows)
        }

        public func expectedTotalRows(visibleRows: UInt64) -> UInt64 {
            UInt64(scrollbackRows) + visibleRows
        }
    }

    public struct MirrorObservation: Equatable, Sendable {
        public let totalRows: UInt64
        public let visibleRows: UInt64
        public let scrollbarOffset: UInt64

        public init(totalRows: UInt64, visibleRows: UInt64, scrollbarOffset: UInt64 = 0) {
            self.totalRows = totalRows
            self.visibleRows = visibleRows
            self.scrollbarOffset = scrollbarOffset
        }

        public var maxScrollableOffset: Double {
            totalRows > visibleRows ? Double(totalRows - visibleRows) : 0
        }
    }

    public enum MirrorRetention: Equatable, Sendable {
        case complete
        case truncated(missingRows: UInt64)

        public var isTruncated: Bool {
            switch self {
            case .complete:
                false
            case .truncated:
                true
            }
        }

        public var missingRows: UInt64 {
            switch self {
            case .complete:
                0
            case .truncated(let missingRows):
                missingRows
            }
        }
    }

    private static let retentionAccountingSlackRows: UInt64 = 1

    public struct BoundsResult: Equatable, Sendable {
        public let rowOffset: Double
        public let maxRowOffset: Double
        public let wasAtBottom: Bool
        public let expectedTotalRows: UInt64
        public let mirrorRetention: MirrorRetention
        public let observation: MirrorObservation

        public var mirrorTruncated: Bool {
            mirrorRetention.isTruncated
        }
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
    public private(set) var visibleRows: UInt64 = 0
    public private(set) var observedTotalRows: UInt64 = 0
    public private(set) var replayWindow = ReplayWindow()
    public private(set) var mirrorRetention: MirrorRetention = .complete

    public var replayScrollbackRows: Int {
        replayWindow.scrollbackRows
    }

    public var mirrorTruncated: Bool {
        mirrorRetention.isTruncated
    }

    private let bottomAnchorPolicy: BottomAnchorPolicy

    private var boundsInitialized = false
    private var anchorToBottomOnNextBounds = false

    public init(bottomAnchorPolicy: BottomAnchorPolicy = BottomAnchorPolicy()) {
        self.bottomAnchorPolicy = bottomAnchorPolicy
    }

    public var isViewingLiveBottom: Bool {
        activeScreen != .primary || bottomAnchorPolicy.isAtBottom(offset: rowOffset, maxOffset: maxRowOffset)
    }

    public mutating func applyMetadata(
        activeScreen: MobileTerminalRenderGridFrame.Screen?,
        scrollbackRows: Int?
    ) -> MetadataResult? {
        if let activeScreen {
            self.activeScreen = activeScreen
        }
        guard let scrollbackRows else { return nil }

        let wasAtBottom = !boundsInitialized || bottomAnchorPolicy.isAtBottom(offset: rowOffset, maxOffset: maxRowOffset)
        anchorToBottomOnNextBounds = wasAtBottom
        replayWindow = ReplayWindow(activeScreen: self.activeScreen, scrollbackRows: scrollbackRows)
        if wasAtBottom, boundsInitialized {
            rowOffset = maxRowOffset
        }
        return MetadataResult(
            rowOffset: rowOffset,
            maxRowOffset: maxRowOffset,
            wasAtBottom: wasAtBottom
        )
    }

    public mutating func updateBounds(total: UInt64, offset: UInt64 = 0, len: UInt64) -> BoundsResult {
        updateBounds(observation: MirrorObservation(totalRows: total, visibleRows: len, scrollbarOffset: offset))
    }

    public mutating func updateBounds(observation: MirrorObservation) -> BoundsResult {
        guard activeScreen == .primary else {
            resetForNonPrimaryScreen()
            return BoundsResult(
                rowOffset: rowOffset,
                maxRowOffset: maxRowOffset,
                wasAtBottom: true,
                expectedTotalRows: 0,
                mirrorRetention: .complete,
                observation: observation
            )
        }

        observedTotalRows = observation.totalRows
        visibleRows = observation.visibleRows
        let expectedTotal = replayWindow.expectedTotalRows(visibleRows: observation.visibleRows)
        mirrorRetention = Self.retention(
            replayWindow: replayWindow,
            observation: observation,
            expectedTotalRows: expectedTotal
        )
        let nextMax = Self.resolvedMaxRowOffset(
            replayWindow: replayWindow,
            observation: observation,
            retention: mirrorRetention
        )
        let previousMax = maxRowOffset
        let wasAtBottom = !boundsInitialized
            || anchorToBottomOnNextBounds
            || bottomAnchorPolicy.isAtBottom(offset: rowOffset, maxOffset: previousMax)

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
            mirrorRetention: mirrorRetention,
            observation: observation
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
        visibleRows = 0
        observedTotalRows = 0
        replayWindow = ReplayWindow(activeScreen: activeScreen, scrollbackRows: 0)
        mirrorRetention = .complete
        boundsInitialized = false
        anchorToBottomOnNextBounds = false
    }

    private static func retention(
        replayWindow: ReplayWindow,
        observation: MirrorObservation,
        expectedTotalRows: UInt64
    ) -> MirrorRetention {
        guard replayWindow.scrollbackRows > 0 else { return .complete }
        guard observation.totalRows + retentionAccountingSlackRows < expectedTotalRows else { return .complete }
        return .truncated(missingRows: expectedTotalRows - observation.totalRows)
    }

    private static func resolvedMaxRowOffset(
        replayWindow: ReplayWindow,
        observation: MirrorObservation,
        retention: MirrorRetention
    ) -> Double {
        if retention.isTruncated {
            return observation.maxScrollableOffset
        }
        return max(observation.maxScrollableOffset, Double(replayWindow.scrollbackRows))
    }
}
