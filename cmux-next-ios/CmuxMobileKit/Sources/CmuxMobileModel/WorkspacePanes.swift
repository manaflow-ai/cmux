import CoreGraphics
import Foundation

/// A workspace's panes as its Mac lays them out (cmux-tui `list-workspaces`: screens, each
/// with a split tree of panes, each pane with its tabs). The phone shows one tab at a time;
/// the Panes page reads this to show which tabs share a pane and to act on panes as the
/// Mac's pane menus do (verify/parity-mac.md, Panes).
public struct WorkspaceLayout: Hashable, Sendable {
    public struct Pane: Identifiable, Hashable, Sendable {
        /// The Mac's pane id (what `split`, `zoom-pane`, `close-pane` and the rest name).
        public var id: Int
        /// The name the person gave the pane on the Mac (Rename Pane…), empty when none.
        public var name: String
        /// The tabs the phone lists, in the pane's order on the Mac.
        public var tabIDs: [String]
        /// The tab the pane shows on the Mac, when the phone lists it.
        public var activeTabID: String?
        /// The pane is its screen's focused pane on the Mac.
        public var isFocused: Bool
        /// The pane is zoomed on the Mac (it fills its screen there).
        public var isZoomed: Bool
        /// Every tab the pane holds on the Mac, listed by the phone or not (a `move-tab` index counts them all).
        public var tabCount: Int

        public init(id: Int, name: String = "", tabIDs: [String], activeTabID: String? = nil,
                    isFocused: Bool = false, isZoomed: Bool = false, tabCount: Int? = nil) {
            self.tabCount = tabCount ?? tabIDs.count
            self.id = id
            self.name = name
            self.tabIDs = tabIDs
            self.activeTabID = activeTabID
            self.isFocused = isFocused
            self.isZoomed = isZoomed
        }
    }

    /// Side by side (`right`: a vertical divider) or stacked (`down`).
    public enum Axis: String, Hashable, Sendable {
        case horizontal = "right"
        case vertical = "down"
    }

    /// The Mac's split tree (`layout`): a pane, a split of two nodes, or a stack of panes
    /// of which one is shown.
    public indirect enum Node: Hashable, Sendable {
        case pane(Int)
        /// `ratio` is the first node's share.
        case split(id: Int, axis: Axis, ratio: Double, first: Node, second: Node)
        case stack([Int], expanded: Int)

        /// Every pane in the node, in tree order.
        public var paneIDs: [Int] {
            switch self {
            case .pane(let id): [id]
            case .split(_, _, _, let first, let second): first.paneIDs + second.paneIDs
            case .stack(let panes, _): panes
            }
        }

        /// The cells along `axis`: the Mac's `SplitNode.cellCount(along:)`.
        func cellCount(along axis: Axis) -> Int {
            switch self {
            case .pane, .stack: 1
            case .split(_, let own, _, let first, let second):
                own == axis ? first.cellCount(along: axis) + second.cellCount(along: axis) : 1
            }
        }

        /// Each split with the ratio that gives every cell of its same-axis chain an equal
        /// share (the Mac's `SplitNode.equalizedRatio(for:)`), outermost first.
        public var equalizedRatios: [EqualizedSplit] {
            switch self {
            case .pane, .stack: return []
            case .split(let id, let axis, let ratio, let first, let second):
                let a = Double(first.cellCount(along: axis))
                let b = Double(second.cellCount(along: axis))
                return [EqualizedSplit(split: id, ratio: ratio, equalized: a / (a + b))]
                    + first.equalizedRatios + second.equalizedRatios
            }
        }

        /// The node without the panes `gone` (dead panes the Mac still keeps a leaf for): a split
        /// whose side is all gone is its other side. Nil when nothing is left.
        public func removing(_ gone: Set<Int>) -> Node? {
            guard !gone.isEmpty else { return self }
            switch self {
            case .pane(let id): return gone.contains(id) ? nil : self
            case .stack(let panes, let expanded):
                let kept = panes.filter { !gone.contains($0) }
                guard let first = kept.first else { return nil }
                return .stack(kept, expanded: kept.contains(expanded) ? expanded : first)
            case .split(let id, let axis, let ratio, let first, let second):
                switch (first.removing(gone), second.removing(gone)) {
                case let (a?, b?): return .split(id: id, axis: axis, ratio: ratio, first: a, second: b)
                case let (a?, nil): return a
                case let (nil, b?): return b
                case (nil, nil): return nil
                }
            }
        }

        /// Each shown pane's frame in `rect` at the split ratios (a stack shows its expanded pane).
        public func frames(in rect: CGRect) -> [Int: CGRect] {
            switch self {
            case .pane(let id): return [id: rect]
            case .stack(_, let expanded): return [expanded: rect]
            case .split(_, let axis, let ratio, let first, let second):
                let share = min(max(ratio, 0.05), 0.95)
                let (a, b) = axis == .horizontal
                    ? rect.divided(atDistance: rect.width * share, from: .minXEdge)
                    : rect.divided(atDistance: rect.height * share, from: .minYEdge)
                return first.frames(in: a).merging(second.frames(in: b)) { lhs, _ in lhs }
            }
        }

        /// The directions `pane` has a neighbor in, read from its splits: a pane in a side by
        /// side split's first half has one to its right, in the second half one to its left.
        func neighbors(of pane: Int) -> Set<PaneSwap> {
            guard case .split(_, let axis, _, let first, let second) = self else { return [] }
            if first.paneIDs.contains(pane) {
                return first.neighbors(of: pane).union([axis == .horizontal ? .right : .down])
            }
            if second.paneIDs.contains(pane) {
                return second.neighbors(of: pane).union([axis == .horizontal ? .left : .up])
            }
            return []
        }
    }

    /// One split's ratio now and the ratio Equalize Splits gives it.
    public struct EqualizedSplit: Hashable, Sendable {
        public var split: Int
        public var ratio: Double
        public var equalized: Double

        public init(split: Int, ratio: Double, equalized: Double) {
            self.split = split
            self.ratio = ratio
            self.equalized = equalized
        }

        /// The split already has its equal share (the daemon keeps float32 ratios).
        public var isEqual: Bool { abs(ratio - equalized) < 0.001 }
    }

    /// A horizontal viewport column of a screen (`columns`): as wide as the Mac draws it (a share
    /// of its viewport; the columns together may be wider than the window, which scrolls), docked
    /// to an edge or scrolling, holding a split tree or rows of them.
    public struct Column: Hashable, Sendable {
        /// One row of a column with rows (`rows-v1`), top to bottom.
        public struct Row: Hashable, Sendable {
            /// Permille of the column's viewport height (the rows may scroll past 1000).
            public var height: Double
            public var root: Node

            public init(height: Double, root: Node) {
                self.height = height
                self.root = root
            }
        }

        /// A column pinned to a viewport edge (`dock`, `dock-columns-v1`, `edge-docks-v1`).
        public struct Dock: Hashable, Sendable {
            public enum Edge: String, Hashable, Sendable { case left, right, top, bottom }
            public var edge: Edge
            /// `mode: "overlay"`: a side dock floats over the scrolling columns, which keep the
            /// full width. A docked one (the default) takes its width out of theirs.
            public var isOverlay: Bool

            public init(edge: Edge, isOverlay: Bool = false) {
                self.edge = edge
                self.isOverlay = isOverlay
            }

            /// Top and bottom: a screen-wide band above or below the scrolling columns.
            public var isBand: Bool { edge == .top || edge == .bottom }
        }

        /// Its width as a share of the Mac's viewport (`width`); a band's height as a share of
        /// the viewport height.
        public var width: Double
        /// Its edge when pinned (`dock`): New Pane (Auto Layout) never splits it.
        public var dock: Dock?
        /// Its split tree; for a column with rows, the rows' compatibility chain.
        public var root: Node?
        /// Its rows, when it has two or more.
        public var rows: [Row]

        public init(width: Double, dock: Dock? = nil, root: Node?, rows: [Row] = []) {
            self.width = width
            self.dock = dock
            self.root = root
            self.rows = rows
        }

        public var isDocked: Bool { dock != nil }

        /// Each shown pane's frame in the column's `rect` (`rect.height` is the viewport's): its
        /// rows at their heights, else its tree at its ratios.
        func frames(in rect: CGRect) -> [Int: CGRect] {
            guard !rows.isEmpty else { return root?.frames(in: rect) ?? [:] }
            var frames: [Int: CGRect] = [:]
            var y = rect.minY
            for row in rows {
                let height = rect.height * CGFloat(max(row.height, 0)) / 1000
                frames.merge(row.root.frames(in: CGRect(x: rect.minX, y: y, width: rect.width, height: height))) { lhs, _ in lhs }
                y += height
            }
            return frames
        }
    }

    public struct Screen: Identifiable, Hashable, Sendable {
        public var id: Int
        public var name: String
        /// The screen the workspace shows on the Mac.
        public var isActive: Bool
        /// Its panes in the order the Mac lists them (tree order).
        public var panes: [Pane]
        /// The whole screen's split tree, nil when the Mac sent none. With viewport columns this
        /// is their compatibility chain, which squeezes every column into one width.
        public var root: Node?
        /// Its viewport columns, in order (empty when the screen is one split tree).
        public var columns: [Column]
        /// The trees Equalize Splits evens out, as the Mac's does: each viewport column's
        /// (each of its rows' when it has rows), else the screen's own tree.
        public var equalizable: [Node]

        public init(id: Int, name: String = "", isActive: Bool, panes: [Pane], root: Node?,
                    columns: [Column] = [], equalizable: [Node]? = nil) {
            self.id = id
            self.name = name
            self.isActive = isActive
            self.panes = panes
            self.root = root
            self.columns = columns
            self.equalizable = equalizable ?? root.map { [$0] } ?? []
        }

        /// The Mac window New Pane (Auto Layout) measures panes in: the phone has none, so a
        /// 16:10 one.
        static let window = CGSize(width: 16, height: 10)

        /// The frames New Pane (Auto Layout) compares, as the Mac lays the screen out
        /// (`ScreenGeometry`, `DockStripGeometry.place`, less its gaps and pixel minimums): with
        /// viewport columns, the scrolling strip is the window less what the docks take (a docked
        /// side dock its width, at most 75% of the window, 40% each with two; a top or bottom
        /// band its height, at most half the window, a third each with two, in either mode), and
        /// each scrolling column is its share of the strip's width at the strip's height, rows at
        /// their heights. Docked columns are never split, so they are left out. Without columns,
        /// the screen's tree in the window.
        public var autoLayoutFrames: [Int: CGRect] {
            guard !columns.isEmpty else { return root?.frames(in: CGRect(origin: .zero, size: Self.window)) ?? [:] }
            let docks = columns.compactMap(\.dock)
            let sides = docks.filter { !$0.isBand }.count, bands = docks.filter(\.isBand).count
            var stripWidth = Self.window.width
            var stripHeight = Self.window.height
            var stripTop: CGFloat = 0
            for column in columns {
                guard let dock = column.dock else { continue }
                let share = CGFloat(max(column.width, 0))
                if dock.isBand {
                    let height = Self.window.height * min(share, bands > 1 ? 1.0 / 3.0 : 0.5)
                    stripHeight -= height
                    if dock.edge == .top { stripTop += height }
                } else if !dock.isOverlay {
                    stripWidth -= Self.window.width * min(share, sides > 1 ? 0.4 : 0.75)
                }
            }
            var frames: [Int: CGRect] = [:]
            var x: CGFloat = 0
            for column in columns where column.dock == nil {
                let width = max(stripWidth, 0) * CGFloat(max(column.width, 0))
                frames.merge(column.frames(in: CGRect(x: x, y: stripTop, width: width, height: max(stripHeight, 0)))) { lhs, _ in lhs }
                x += width
            }
            return frames
        }

        /// New Pane (Auto Layout), as the Mac's (Zellij's new pane, `PanePlacement.autoSplit`):
        /// the largest shown scrolling pane splits along its longer side (right on a tie), never
        /// a docked column. Sizes are read in a 16:10 Mac window, viewport columns at their own
        /// widths.
        public var autoLayoutSplit: (pane: Int, direction: PaneSplit)? {
            let order = panes.map(\.id)
            let frames = autoLayoutFrames.filter { order.contains($0.key) && $0.value.width > 0 && $0.value.height > 0 }
            guard let (pane, frame) = frames.max(by: { lhs, rhs in
                let (a, b) = (lhs.value.width * lhs.value.height, rhs.value.width * rhs.value.height)
                // A tie goes to the pane listed first.
                return abs(a - b) < 0.0001 ? (order.firstIndex(of: lhs.key) ?? 0) > (order.firstIndex(of: rhs.key) ?? 0) : a < b
            }) else {
                // No frame to compare (no tree from the Mac): the first scrolling pane, split right.
                let docked = Set(columns.filter(\.isDocked).flatMap { $0.root?.paneIDs ?? [] })
                return order.first { !docked.contains($0) }.map { ($0, .right) }
            }
            return (pane, frame.width >= frame.height ? .right : .down)
        }

        /// The splits Equalize Splits would change.
        public var unequalSplits: [EqualizedSplit] { equalizable.flatMap(\.equalizedRatios).filter { !$0.isEqual } }
        /// The screen has a divider at all (Equalize Splits has something to even out).
        public var hasSplits: Bool { equalizable.contains { !$0.equalizedRatios.isEmpty } }
    }

    public var screens: [Screen]

    public init(screens: [Screen]) {
        self.screens = screens
    }

    /// The screen the workspace shows on the Mac (its first when none is marked).
    public var activeScreen: Screen? { screens.first(where: \.isActive) ?? screens.first }
    public var panes: [Pane] { screens.flatMap(\.panes) }

    public func pane(_ id: Int) -> Pane? { panes.first { $0.id == id } }
    public func pane(holding tabID: String) -> Pane? { panes.first { $0.tabIDs.contains(tabID) } }
    public func screen(of pane: Int) -> Screen? { screens.first { $0.panes.contains { $0.id == pane } } }

    /// "Pane 2" for an unnamed pane: its place on its screen, as the Mac's Focus Pane 1…9 counts.
    public func title(of pane: Pane) -> String {
        if !pane.name.isEmpty { return pane.name }
        let index = screen(of: pane.id)?.panes.firstIndex { $0.id == pane.id } ?? 0
        return "Pane \(index + 1)"
    }

    /// The directions Swap Pane can go from `pane` (a neighbor on that side).
    public func swapDirections(of pane: Int) -> [PaneSwap] {
        let found = screen(of: pane)?.root?.neighbors(of: pane) ?? []
        return PaneSwap.allCases.filter(found.contains)
    }

    /// The other panes of `pane`'s screen, the places Move Tab to Pane… offers.
    public func otherPanes(than pane: Int) -> [Pane] {
        (screen(of: pane)?.panes ?? []).filter { $0.id != pane }
    }
}

/// The Mac's Split Right / Down / Left / Up (`PaneActionCatalog`, `LayoutActionCatalog`): a new
/// pane beside the pane with a new terminal in it. The daemon splits right or down; a left or
/// up split then swaps the two panes, as the Mac's fork to the left does.
public enum PaneSplit: String, CaseIterable, Hashable, Sendable {
    case right, down, left, up

    public var title: String {
        switch self {
        case .right: "Split Right"
        case .down: "Split Down"
        case .left: "Split Left"
        case .up: "Split Up"
        }
    }

    public var systemImage: String {
        switch self {
        case .right: "rectangle.split.2x1"
        case .down: "rectangle.split.1x2"
        case .left: "rectangle.lefthalf.inset.filled"
        case .up: "rectangle.tophalf.inset.filled"
        }
    }

    /// The `split` command's `dir`.
    public var daemonDirection: String { self == .right || self == .left ? "right" : "down" }
    /// The new pane goes before the old one: the daemon's split, then a swap of the two.
    public var swapsAfter: Bool { self == .left || self == .up }
}

/// The Mac's Swap Pane Left / Right / Up / Down (`swap-pane {pane, dir}`).
public enum PaneSwap: String, CaseIterable, Hashable, Sendable {
    case left, right, up, down

    public var title: String {
        switch self {
        case .left: "Swap Pane Left"
        case .right: "Swap Pane Right"
        case .up: "Swap Pane Up"
        case .down: "Swap Pane Down"
        }
    }

    public var systemImage: String { "arrowshape.\(rawValue)" }
}

/// Move Tab to New Split's side (`move-tab-to-split {edge}`), the Mac's `direction` argument.
public enum TabSplitEdge: String, CaseIterable, Hashable, Sendable {
    case right, left, up, down

    /// `move-tab-to-split`'s `edge`.
    public var daemonEdge: String {
        switch self {
        case .right: "right"
        case .left: "left"
        case .up: "top"
        case .down: "bottom"
        }
    }

    public var title: String {
        switch self {
        case .right: "To the Right"
        case .left: "To the Left"
        case .up: "Above"
        case .down: "Below"
        }
    }

    public var systemImage: String {
        switch self {
        case .right: "rectangle.righthalf.inset.filled"
        case .left: "rectangle.lefthalf.inset.filled"
        case .up: "rectangle.tophalf.inset.filled"
        case .down: "rectangle.bottomhalf.inset.filled"
        }
    }
}

/// Where Fork Conversation opens the copy (the Mac's `AgentForkDestination`, less New Window).
public enum ChatForkDestination: String, CaseIterable, Hashable, Sendable, Identifiable {
    case right, left, up, down, tab, workspace
    public var id: String { rawValue }

    /// The choice in the phone's Fork Conversation list.
    public var title: String {
        switch self {
        case .right: "To the Right"
        case .left: "To the Left"
        case .up: "Above"
        case .down: "Below"
        case .tab: "In a New Tab"
        case .workspace: "In a New Workspace"
        }
    }

    /// The Mac's action title (`palette.forkAgentConversation…`).
    public var macTitle: String {
        switch self {
        case .right: "Fork Conversation to the Right"
        case .left: "Fork Conversation to the Left"
        case .up: "Fork Conversation Above"
        case .down: "Fork Conversation Below"
        case .tab: "Fork Conversation to New Tab"
        case .workspace: "Fork Conversation to New Workspace"
        }
    }

    /// A split destination's side: the fork opens as a tab beside the chat, then moves there
    /// (`move-tab-to-split`), as the Mac's `openFork` does.
    public var splitEdge: TabSplitEdge? {
        switch self {
        case .right: .right
        case .left: .left
        case .up: .up
        case .down: .down
        case .tab, .workspace: nil
        }
    }
}

/// What Undo Layout Change did (`undo-layout`, `layout-undo-v1`).
public enum LayoutUndoOutcome: Hashable, Sendable {
    case undone
    /// The change made panes; undoing it closes some. The person's yes sends it back.
    case needsConfirmation(LayoutUndoConfirmation)
}

/// An Undo Layout Change that closes panes, as the Mac asked about it: the screen it undoes on,
/// the pane that named that screen, and the screen's undo `revision`. The yes goes to exactly
/// this screen (`undo-layout {pane, revision, confirm_close}`), even when the Mac shows another
/// one by then: revisions count per screen, so another screen's could match.
public struct LayoutUndoConfirmation: Hashable, Sendable, Identifiable {
    public var screen: Int
    public var pane: Int
    public var revision: UInt64
    /// How many panes the undo closes.
    public var closing: Int

    public init(screen: Int, pane: Int, revision: UInt64, closing: Int) {
        self.screen = screen
        self.pane = pane
        self.revision = revision
        self.closing = closing
    }

    public var id: String { "\(screen).\(revision)" }
}

/// The Mac's pane and layout actions, on the workspace's Mac (verify/parity-mac.md, Panes).
@MainActor
public protocol WorkspacePaneBackend: AnyObject {
    /// Whether panes can be changed on `macID` now.
    func canEditPanes(on macID: String) -> Bool
    /// Split Right / Down / Left / Up: a new pane beside `pane` with a new terminal in it,
    /// returned once the Mac lists it.
    func split(_ pane: Int, _ direction: PaneSplit, in workspace: Workspace) async throws -> WorkspaceTab
    /// New Pane (Auto Layout) (a split of the screen's largest pane along its longer side, as the
    /// Mac's) or New Column (`new-pane-right`, a viewport column after `pane`'s).
    func newPane(from pane: Int, column: Bool, in workspace: Workspace) async throws -> WorkspaceTab
    /// Toggle Pane Zoom.
    func toggleZoom(_ pane: Int, in workspace: Workspace) async throws
    /// Swap Pane Left / Right / Up / Down.
    func swap(_ pane: Int, _ direction: PaneSwap, in workspace: Workspace) async throws
    /// Rename Pane… (an empty name clears it).
    func renamePane(_ pane: Int, to name: String, in workspace: Workspace) async throws
    /// Close Pane: the pane and its tabs; each terminal no other tab shows ends, as a closed tab's does.
    func closePane(_ pane: Int, in workspace: Workspace) async throws
    /// Equalize Splits on the workspace's shown screen; the number of splits it changed.
    func equalizeSplits(in workspace: Workspace) async throws -> Int
    /// Undo Layout Change on the workspace's shown screen. `confirmation`: the person's yes to
    /// an undo that closes panes, from an earlier `.needsConfirmation`; it goes to the screen
    /// that question was about.
    func undoLayout(in workspace: Workspace, confirming confirmation: LayoutUndoConfirmation?) async throws -> LayoutUndoOutcome
    /// Move Tab to New Split: a new pane on `edge` of the tab's pane, holding the tab.
    func moveTab(_ tab: WorkspaceTab, toNewSplit edge: TabSplitEdge, in workspace: Workspace) async throws
    /// Move Tab to New Column: a new viewport column after the screen's last, holding the tab (as the Mac's).
    func moveTabToNewColumn(_ tab: WorkspaceTab, in workspace: Workspace) async throws
    /// Move Tab to Pane…: the end of another pane's tabs.
    func moveTab(_ tab: WorkspaceTab, toPane pane: Int, in workspace: Workspace) async throws
    /// Fork Conversation to `destination`: a copy of the chat beside it, in a new tab, or in a
    /// new workspace; returned once the Mac lists it there.
    func forkAgentChat(_ tab: WorkspaceTab, to destination: ChatForkDestination, in workspace: Workspace) async throws -> WorkspaceTab
}
