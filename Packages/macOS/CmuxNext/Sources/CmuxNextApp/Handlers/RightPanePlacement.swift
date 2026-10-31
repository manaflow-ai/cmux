public import CoreGraphics

/// The placement policy shared by links, document viewers and session opens that originate in an
/// agent chat.  The policy is deliberately a value type: callers gather their own pane snapshot,
/// ask once, and then perform the returned daemon operation.  This keeps geometric right-neighbour
/// lookup, tab order and session-vs-document splits from drifting between open paths.
public nonisolated struct RightPanePlacement {
    public nonisolated init() {}
    /// The smallest useful chat width after making the first right-hand area.
    public static let minimumChatWidth: CGFloat = 480
    /// The smallest useful width for the right-hand area itself.
    public static let minimumRightColumnWidth: CGFloat = 420

    public enum Kind: Sendable, Hashable {
        case documents
        case session
    }

    /// A tab already in one of the right column's areas. `id` is a stable surface or page key;
    /// callers use it for deduplication and to locate the resulting tab.
    public struct Item: Sendable, Hashable {
        public let id: String
        public init(id: String) { self.id = id }
    }

    /// The tabs in one area, in strip order, and the selected tab in that area.
    public struct Area: Sendable, Hashable {
        public let tabs: [Item]
        public let active: String?

        public init(tabs: [Item] = [], active: String? = nil) {
            self.tabs = tabs
            self.active = active
        }

        var insertionAnchor: String? {
            guard let active, tabs.contains(where: { $0.id == active }) else { return tabs.last?.id }
            return active
        }
    }

    /// The single operation all four native open engines perform after taking a snapshot.
    public enum Decision: Sendable, Hashable {
        /// There is no right area yet; create it beside the chat and put the item in its top area.
        case createRightColumn
        /// A document or session should be inserted in this existing area immediately after its
        /// active tab. `anchor` is nil for an empty area.
        case openTab(kind: Kind, anchor: String?)
        /// The first session needs its own lower area. Split the top-right area below its existing
        /// content, then open the session in that new area.
        case splitSessionsBelowDocuments
        /// The requested item is already present in this right column; select it in place.
        case selectExisting(String)
        /// Splitting would leave the chat or right area unusably narrow. Keep the item as a tab in
        /// the matching area, preserving the active-tab insertion rule where possible.
        case openTabWithoutSplit(kind: Kind, anchor: String?)
        /// There is no right area and the chat cannot afford one. The caller keeps the item in its
        /// current pane rather than creating a split.
        case openInChat
    }

    /// Chooses the operation for an item. `rightColumnWidth` is zero when no right column exists;
    /// widths are measured in points by the caller, so this policy works for both live windows and
    /// deterministic layout tests. The main-pane strip passes its top-right pane as `documents`.
    public static func decide(kind: Kind, identity: String, chatWidth: CGFloat,
                              rightColumnWidth: CGFloat, documents: Area = Area(), sessions: Area = Area()) -> Decision {
        if let existing = documents.tabs.first(where: { $0.id == identity }) ?? sessions.tabs.first(where: { $0.id == identity }) {
            return .selectExisting(existing.id)
        }

        guard rightColumnWidth > 0 else {
            return chatWidth < minimumChatWidth ? .openInChat : .createRightColumn
        }

        let narrow = chatWidth < minimumChatWidth || rightColumnWidth < minimumRightColumnWidth
        switch kind {
        case .documents:
            let anchor = documents.insertionAnchor
            return narrow ? .openTabWithoutSplit(kind: .documents, anchor: anchor) : .openTab(kind: .documents, anchor: anchor)
        case .session:
            // A right column may have been created by another document engine before this policy
            // sees its first session. It still gets one bottom area: the top-right pane is the
            // split anchor even when its document snapshot is empty.
            if sessions.tabs.isEmpty && !narrow {
                return .splitSessionsBelowDocuments
            }
            let anchor = sessions.insertionAnchor
            return narrow ? .openTabWithoutSplit(kind: .session, anchor: anchor) : .openTab(kind: .session, anchor: anchor)
        }
    }
}
