import Foundation

/// The spatial pane/tab structure of a workspace as arranged on the Mac.
///
/// A workspace on the Mac is a binary split tree: split nodes carry an
/// orientation and a divider ratio, leaves are panes, and every pane holds an
/// ordered stack of tabs (one selected). This value model mirrors that tree so
/// the phone can express the same structure (tab strip grouped by pane, the
/// workspace map, and spatial paging order). It is a pure value: no RPC,
/// connection, or rendering concerns.
public struct MobileWorkspacePaneLayout: Equatable, Sendable {
    /// The split axis of a split node, in the Mac's terms: `horizontal` splits
    /// side-by-side (children left/right), `vertical` splits stacked
    /// (children top/bottom).
    public enum Orientation: String, Equatable, Sendable {
        case horizontal
        case vertical
    }

    /// One tab inside a pane. Terminal tabs share the id space of
    /// ``MobileTerminalPreview`` (both are the Mac's stable panel/surface id),
    /// so a layout tab can be joined back to its streamed terminal.
    public struct Tab: Identifiable, Equatable, Sendable {
        /// What the tab hosts on the Mac. Only terminals stream to the phone;
        /// other kinds render as informational placeholders.
        public enum Kind: String, Equatable, Sendable {
            case terminal
            case browser
            case other
        }

        /// The Mac's stable panel/surface identifier for this tab.
        public var id: MobileTerminalPreview.ID
        /// What the tab hosts.
        public var kind: Kind
        /// The tab's user-facing title.
        public var title: String

        /// Creates a layout tab.
        public init(id: MobileTerminalPreview.ID, kind: Kind, title: String) {
            self.id = id
            self.kind = kind
            self.title = title
        }
    }

    /// One pane (a leaf region of the split tree) and its tab stack.
    public struct Pane: Identifiable, Equatable, Sendable {
        /// A stable, string-backed identifier for a pane.
        public struct ID: RawRepresentable, Hashable, Sendable, ExpressibleByStringLiteral {
            /// The backing pane identifier string.
            public var rawValue: String

            /// Creates an identifier from its raw string value.
            public init(rawValue: String) {
                self.rawValue = rawValue
            }

            /// Creates an identifier from a string literal.
            public init(stringLiteral value: String) {
                self.rawValue = value
            }
        }

        /// The pane's stable identifier.
        public var id: ID
        /// The pane's tabs, in the Mac's tab-strip order.
        public var tabs: [Tab]
        /// The tab currently selected in this pane on the Mac, when known.
        public var selectedTabID: MobileTerminalPreview.ID?

        /// Creates a pane.
        public init(id: ID, tabs: [Tab], selectedTabID: MobileTerminalPreview.ID? = nil) {
            self.id = id
            self.tabs = tabs
            self.selectedTabID = selectedTabID
        }

        /// The pane's selected tab, falling back to its first tab.
        public var selectedTab: Tab? {
            tabs.first { $0.id == selectedTabID } ?? tabs.first
        }
    }

    /// A node of the split tree.
    public indirect enum Node: Equatable, Sendable {
        /// A split region: `ratio` is the fraction of the region the first
        /// child occupies along the split axis (0...1).
        case split(orientation: Orientation, ratio: Double, first: Node, second: Node)
        /// A leaf region hosting one pane.
        case pane(Pane)
    }

    /// The root of the split tree.
    public var root: Node

    /// Creates a layout from its root node.
    public init(root: Node) {
        self.root = root
    }

    /// Creates a single-pane layout, the shape reported for an unsplit
    /// workspace and the fallback for Macs too old to report layout.
    ///
    /// - Parameters:
    ///   - terminals: The workspace's terminals, in display order.
    ///   - selectedTabID: The tab to mark selected; defaults to the focused
    ///     terminal, then the first.
    public static func singlePane(
        terminals: [MobileTerminalPreview],
        selectedTabID: MobileTerminalPreview.ID? = nil
    ) -> MobileWorkspacePaneLayout {
        let tabs = terminals.map { terminal in
            Tab(id: terminal.id, kind: .terminal, title: terminal.name)
        }
        let selected = selectedTabID
            ?? terminals.first(where: \.isFocused)?.id
            ?? terminals.first?.id
        return MobileWorkspacePaneLayout(
            root: .pane(Pane(id: "pane-0", tabs: tabs, selectedTabID: selected))
        )
    }

    /// The panes in depth-first (spatial) order — the same order the Mac uses
    /// for its flattened `terminals[]` list.
    public var panes: [Pane] {
        Self.collectPanes(from: root)
    }

    /// Every tab in spatial order: panes depth-first, tabs in pane order.
    public var orderedTabs: [Tab] {
        panes.flatMap(\.tabs)
    }

    /// The pane containing `tabID`, if any.
    public func pane(containing tabID: MobileTerminalPreview.ID) -> Pane? {
        panes.first { pane in pane.tabs.contains { $0.id == tabID } }
    }

    /// The number of panes (leaf regions).
    public var paneCount: Int {
        panes.count
    }

    private static func collectPanes(from node: Node) -> [Pane] {
        switch node {
        case let .pane(pane):
            return [pane]
        case let .split(_, _, first, second):
            return collectPanes(from: first) + collectPanes(from: second)
        }
    }

    /// A copy without `tabID`, mirroring the Mac's close semantics: a pane
    /// left empty collapses, and a split with one collapsed child is replaced
    /// by the surviving child. Returns `nil` when the last tab was removed
    /// (the workspace-level close case, which the phone never issues).
    ///
    /// Used for the optimistic close: the authoritative tree re-arrives via
    /// the next workspace-list sync.
    public func removingTab(_ tabID: MobileTerminalPreview.ID) -> MobileWorkspacePaneLayout? {
        Self.removeTab(tabID, from: root).map(MobileWorkspacePaneLayout.init(root:))
    }

    private static func removeTab(_ tabID: MobileTerminalPreview.ID, from node: Node) -> Node? {
        switch node {
        case let .pane(pane):
            var copy = pane
            copy.tabs.removeAll { $0.id == tabID }
            guard !copy.tabs.isEmpty else { return nil }
            if copy.selectedTabID == tabID {
                copy.selectedTabID = copy.tabs.first?.id
            }
            return .pane(copy)
        case let .split(orientation, ratio, first, second):
            let newFirst = removeTab(tabID, from: first)
            let newSecond = removeTab(tabID, from: second)
            switch (newFirst, newSecond) {
            case let (.some(f), .some(s)):
                return .split(orientation: orientation, ratio: ratio, first: f, second: s)
            case let (.some(survivor), nil), let (nil, .some(survivor)):
                return survivor
            case (nil, nil):
                return nil
            }
        }
    }
}
