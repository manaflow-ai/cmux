public import CMUXMobileCore
import Foundation

/// Value model for the phone-local primary-screen scrollback mirror.
///
/// The Mac owns terminal history and sends a bounded render-grid replay. The
/// iOS Ghostty surface is only a local mirror of that window, so scroll range
/// is derived from the retained Ghostty mirror in one place. Replay metadata is
/// used to report whether that mirror is complete or truncated.
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
        public let mirrorBudget: MobileTerminalScrollbackMirrorBudget

        public init(
            activeScreen: MobileTerminalRenderGridFrame.Screen = .primary,
            scrollbackRows: Int = 0,
            mirrorBudget: MobileTerminalScrollbackMirrorBudget = MobileTerminalScrollbackBudget.localMirror
        ) {
            self.activeScreen = activeScreen
            self.scrollbackRows = max(0, scrollbackRows)
            self.mirrorBudget = mirrorBudget
        }

        public func expectedTotalRows(visibleRows: UInt64) -> UInt64 {
            mirrorBudget.expectedTotalRows(scrollbackRows: scrollbackRows, visibleRows: visibleRows)
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

    public enum MirrorHydration: Equatable, Sendable {
        case unhydrated
        case hydrated(retainedRows: UInt64)
        case incomplete(missingRows: UInt64)

        public var canServePrimaryScrollLocally: Bool {
            switch self {
            case .hydrated:
                true
            case .unhydrated, .incomplete:
                false
            }
        }

        public var requiresHostHydration: Bool {
            !canServePrimaryScrollLocally
        }
    }

    public struct MirrorRetentionPolicy: Equatable, Sendable {
        public let accountingSlackRows: UInt64

        public init(accountingSlackRows: UInt64 = MobileTerminalScrollbackBudget.retentionAccountingSlackRows) {
            self.accountingSlackRows = accountingSlackRows
        }

        public func retention(
            replayWindow: ReplayWindow,
            observation: MirrorObservation,
            expectedTotalRows: UInt64
        ) -> MirrorRetention {
            guard replayWindow.scrollbackRows > 0 else { return .complete }
            guard observation.totalRows + accountingSlackRows < expectedTotalRows else { return .complete }
            return .truncated(missingRows: expectedTotalRows - observation.totalRows)
        }
    }

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
    public private(set) var mirrorHydration: MirrorHydration = .unhydrated

    public var replayScrollbackRows: Int {
        replayWindow.scrollbackRows
    }

    public var mirrorTruncated: Bool {
        mirrorRetention.isTruncated
    }

    public var canServePrimaryScrollLocally: Bool {
        activeScreen == .primary && mirrorHydration.canServePrimaryScrollLocally
    }

    public var requiresHostScrollHydration: Bool {
        activeScreen == .primary && mirrorHydration.requiresHostHydration
    }

    public mutating func requestsHostHydrationForGesture(rowDelta: Double) -> Bool {
        guard activeScreen == .primary,
              canServePrimaryScrollLocally,
              !hasRequestedFullScrollbackHydration,
              replayWindow.scrollbackRows == replayWindow.mirrorBudget.defaultReplayRows,
              rowDelta > 0 else {
            return false
        }
        guard rowOffset - rowDelta <= 0 else { return false }
        hasRequestedFullScrollbackHydration = true
        return true
    }

    private let bottomAnchorPolicy: BottomAnchorPolicy
    private let mirrorRetentionPolicy: MirrorRetentionPolicy

    private enum BoundsState: Equatable, Sendable {
        case unobserved
        case observed
    }

    private enum PendingAnchor: Equatable, Sendable {
        case none
        case bottomOnNextBounds
    }

    private var boundsState: BoundsState = .unobserved
    private var pendingAnchor: PendingAnchor = .none
    private var hasAuthoritativeReplayMetadata = false
    private var hasRequestedFullScrollbackHydration = false

    public init(
        bottomAnchorPolicy: BottomAnchorPolicy = BottomAnchorPolicy(),
        mirrorRetentionPolicy: MirrorRetentionPolicy = MirrorRetentionPolicy()
    ) {
        self.bottomAnchorPolicy = bottomAnchorPolicy
        self.mirrorRetentionPolicy = mirrorRetentionPolicy
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

        let wasAtBottom = boundsState == .unobserved
            || bottomAnchorPolicy.isAtBottom(offset: rowOffset, maxOffset: maxRowOffset)
        pendingAnchor = wasAtBottom ? .bottomOnNextBounds : .none
        replayWindow = ReplayWindow(activeScreen: .primary, scrollbackRows: scrollbackRows)
        if wasAtBottom, boundsState == .observed {
            rowOffset = maxRowOffset
        }
        hasAuthoritativeReplayMetadata = true
        if scrollbackRows != replayWindow.mirrorBudget.defaultReplayRows {
            hasRequestedFullScrollbackHydration = scrollbackRows > replayWindow.mirrorBudget.defaultReplayRows
        }
        mirrorHydration = .unhydrated
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
            resetVisibleScrollForNonPrimaryScreen(observation: observation)
            return BoundsResult(
                rowOffset: rowOffset,
                maxRowOffset: maxRowOffset,
                wasAtBottom: true,
                expectedTotalRows: replayWindow.expectedTotalRows(visibleRows: observation.visibleRows),
                mirrorRetention: mirrorRetention,
                observation: observation
            )
        }

        observedTotalRows = observation.totalRows
        visibleRows = observation.visibleRows
        let expectedTotal = replayWindow.expectedTotalRows(visibleRows: observation.visibleRows)
        mirrorRetention = mirrorRetentionPolicy.retention(
            replayWindow: replayWindow,
            observation: observation,
            expectedTotalRows: expectedTotal
        )
        if hasAuthoritativeReplayMetadata {
            switch mirrorRetention {
            case .complete:
                mirrorHydration = .hydrated(retainedRows: observation.totalRows)
            case .truncated(let missingRows):
                mirrorHydration = .incomplete(missingRows: missingRows)
            }
        } else {
            mirrorHydration = .unhydrated
        }
        let nextMax = observation.maxScrollableOffset
        let previousMax = maxRowOffset
        let wasAtBottom = boundsState == .unobserved
            || pendingAnchor == .bottomOnNextBounds
            || bottomAnchorPolicy.isAtBottom(offset: rowOffset, maxOffset: previousMax)

        maxRowOffset = nextMax
        boundsState = .observed
        if wasAtBottom || rowOffset > nextMax {
            rowOffset = nextMax
        }
        pendingAnchor = .none

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

    private mutating func resetVisibleScrollForNonPrimaryScreen(observation: MirrorObservation) {
        rowOffset = 0
        maxRowOffset = 0
        visibleRows = observation.visibleRows
        observedTotalRows = observation.totalRows
        boundsState = .unobserved
        pendingAnchor = .none
    }
}
