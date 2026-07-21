import SwiftUI

/// Stable transcript attachment state. Appends follow the tail only while
/// `followingTail`; every other state preserves the visible row anchor.
public enum ConversationFollowState<ID: Hashable>: Equatable {
    case followingTail
    case detached(anchorID: ID?, offset: CGFloat, unseenCount: Int)
    case jumpingToHead
    case jumpingToTail
}

public enum ConversationScrollTarget: Equatable, Sendable {
    case head
    case tail
}

/// A generation-keyed semantic scroll request.
public struct ConversationScrollCommand: Equatable, Sendable {
    public let generation: Int
    public let target: ConversationScrollTarget
    public let animated: Bool

    public init(generation: Int, target: ConversationScrollTarget, animated: Bool = true) {
        self.generation = generation
        self.target = target
        self.animated = animated
    }
}

struct ConversationPrefetchGate<ID: Hashable> {
    private(set) var beforeKey: ID?
    private(set) var afterKey: ID?

    mutating func shouldLoadBefore(hasMore: Bool, distance: CGFloat, firstID: ID?) -> Bool {
        guard hasMore else {
            beforeKey = nil
            return false
        }
        guard distance <= 160, beforeKey != firstID else { return false }
        beforeKey = firstID
        return true
    }

    mutating func shouldLoadAfter(hasMore: Bool, distance: CGFloat, lastID: ID?) -> Bool {
        guard hasMore else {
            afterKey = nil
            return false
        }
        guard distance <= 160, afterKey != lastID else { return false }
        afterKey = lastID
        return true
    }

    mutating func reset() {
        beforeKey = nil
        afterKey = nil
    }
}

enum ConversationPrefetchBoundary<ID: Hashable>: Hashable {
    case row(ID)
    case page(String)
}

struct ConversationAppendDelta {
    static func count<ID: Hashable>(previous: [ID], current: [ID]) -> Int {
        guard !previous.isEmpty else { return 0 }
        let currentIDs = Set(current)
        guard let commonID = previous.reversed().first(where: currentIDs.contains),
              let previousIndex = previous.lastIndex(of: commonID),
              let currentIndex = current.lastIndex(of: commonID)
        else { return 0 }
        let removedSuffixCount = previous.distance(from: previous.index(after: previousIndex), to: previous.endIndex)
        let newSuffixCount = current.distance(from: current.index(after: currentIndex), to: current.endIndex)
        return max(0, newSuffixCount - removedSuffixCount)
    }
}

struct ConversationTailGeometry {
    static func maximumOffset(
        contentHeight: CGFloat,
        viewportHeight: CGFloat,
        topInset: CGFloat,
        bottomInset: CGFloat
    ) -> CGFloat {
        max(-topInset, contentHeight - viewportHeight + bottomInset)
    }

    static func distance(
        contentOffset: CGFloat,
        contentHeight: CGFloat,
        viewportHeight: CGFloat,
        topInset: CGFloat,
        bottomInset: CGFloat
    ) -> CGFloat {
        max(0, maximumOffset(
            contentHeight: contentHeight,
            viewportHeight: viewportHeight,
            topInset: topInset,
            bottomInset: bottomInset
        ) - contentOffset)
    }
}

/// Chronological, self-sizing native transcript optimized for large windows.
/// Rows keep stable identity and UIKit creates only visible hosting cells.
public struct NativeConversationTranscript<Row, RowContent>: View
where Row: Identifiable & Equatable, Row.ID: Hashable & Sendable, RowContent: View {
    private let rows: [Row]
    private let hasMoreBefore: Bool
    private let hasMoreAfter: Bool
    private let followState: Binding<ConversationFollowState<Row.ID>>
    private let command: ConversationScrollCommand?
    private let renderGeneration: Int
    private let isActive: Bool
    private let beforePageID: String?
    private let afterPageID: String?
    private let prefetchResetGeneration: Int
    private let onLoadBefore: () -> Void
    private let onLoadAfter: () -> Void
    private let onSemanticHead: () -> Void
    private let onSemanticTail: () -> Void
    private let rowContent: (Row) -> RowContent

    public init(
        rows: [Row],
        hasMoreBefore: Bool,
        hasMoreAfter: Bool = false,
        followState: Binding<ConversationFollowState<Row.ID>>,
        command: ConversationScrollCommand? = nil,
        renderGeneration: Int = 0,
        isActive: Bool = true,
        beforePageID: String? = nil,
        afterPageID: String? = nil,
        prefetchResetGeneration: Int = 0,
        onLoadBefore: @escaping () -> Void = {},
        onLoadAfter: @escaping () -> Void = {},
        onSemanticHead: @escaping () -> Void = {},
        onSemanticTail: @escaping () -> Void = {},
        @ViewBuilder rowContent: @escaping (Row) -> RowContent
    ) {
        self.rows = rows
        self.hasMoreBefore = hasMoreBefore
        self.hasMoreAfter = hasMoreAfter
        self.followState = followState
        self.command = command
        self.renderGeneration = renderGeneration
        self.isActive = isActive
        self.beforePageID = beforePageID
        self.afterPageID = afterPageID
        self.prefetchResetGeneration = prefetchResetGeneration
        self.onLoadBefore = onLoadBefore
        self.onLoadAfter = onLoadAfter
        self.onSemanticHead = onSemanticHead
        self.onSemanticTail = onSemanticTail
        self.rowContent = rowContent
    }

    public var body: some View {
        #if os(iOS)
        NativeConversationTableRepresentable(
            rows: rows,
            hasMoreBefore: hasMoreBefore,
            hasMoreAfter: hasMoreAfter,
            followState: followState,
            command: command,
            renderGeneration: renderGeneration,
            isActive: isActive,
            beforePageID: beforePageID,
            afterPageID: afterPageID,
            prefetchResetGeneration: prefetchResetGeneration,
            onLoadBefore: onLoadBefore,
            onLoadAfter: onLoadAfter,
            onSemanticHead: onSemanticHead,
            onSemanticTail: onSemanticTail,
            rowContent: rowContent
        )
        #else
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(rows) { row in
                    rowContent(row)
                }
            }
        }
        #endif
    }
}
