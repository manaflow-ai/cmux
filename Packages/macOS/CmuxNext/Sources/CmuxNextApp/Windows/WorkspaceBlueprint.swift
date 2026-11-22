import CmuxNextDaemon
import Foundation

/// A workspace's shape without its processes: screens, columns, the split
/// tree, and per pane the tabs (a terminal's directory, a page's URL).
/// Duplicate Workspace captures one and builds a new workspace from it with
/// new terminals (`WorkspaceBlueprintBuilder`); a duplicate never shares a
/// running terminal.
struct WorkspaceBlueprint: Hashable, Sendable, Codable {
    var name: String
    var color: String?
    var icon: String?
    var screens: [Screen]

    struct Screen: Hashable, Sendable, Codable {
        var name: String?
        /// Scrolling columns left to right; one entry for a split screen.
        var columns: [Column]
    }

    struct Column: Hashable, Sendable, Codable {
        /// Fraction of the viewport; nil for a split screen's only column.
        var width: Double?
        var root: Node
    }

    indirect enum Node: Hashable, Sendable, Codable {
        case pane([Tab])
        case split(direction: SplitDirection, ratio: Double, a: Node, b: Node)
    }

    enum Tab: Hashable, Sendable, Codable {
        case terminal(cwd: String?)
        /// `profile`: the tab's browser profile (nil: `default`); a
        /// duplicate reopens the page in the same profile.
        case browser(url: String, engine: BrowserEngine?, profile: String? = nil)

        var isTerminal: Bool {
            if case .terminal = self { return true }
            return false
        }
    }

    /// The first terminal's directory: where the new workspace starts.
    var firstDirectory: String? {
        for tab in screens.lazy.flatMap({ $0.columns }).flatMap({ $0.root.tabs }) {
            if case .terminal(let cwd?) = tab { return cwd }
        }
        return nil
    }

    /// The same shape without browser tabs: a pane left with no tab goes
    /// away and its split collapses into the sibling. With nothing left, one
    /// terminal in `fallbackDirectory`.
    func withoutBrowserTabs(fallbackDirectory: String?) -> WorkspaceBlueprint {
        var copy = self
        copy.screens = screens.compactMap { screen in
            let columns = screen.columns.compactMap { column in column.root.keepingTerminals.map { Column(width: column.width, root: $0) } }
            return columns.isEmpty ? nil : Screen(name: screen.name, columns: columns)
        }
        if copy.screens.isEmpty {
            copy.screens = [Screen(name: nil, columns: [Column(width: nil, root: .pane([.terminal(cwd: fallbackDirectory)]))])]
        }
        return copy
    }
}

extension WorkspaceBlueprint.Node {
    /// Tabs in depth-first pane order.
    var tabs: [WorkspaceBlueprint.Tab] {
        switch self {
        case .pane(let tabs): tabs
        case .split(_, _, let a, let b): a.tabs + b.tabs
        }
    }

    var paneCount: Int {
        switch self {
        case .pane: 1
        case .split(_, _, let a, let b): a.paneCount + b.paneCount
        }
    }

    fileprivate var keepingTerminals: Self? {
        switch self {
        case .pane(let tabs):
            let kept = tabs.filter(\.isTerminal)
            return kept.isEmpty ? nil : .pane(kept)
        case .split(let direction, let ratio, let a, let b):
            switch (a.keepingTerminals, b.keepingTerminals) {
            case let (a?, b?): return .split(direction: direction, ratio: ratio, a: a, b: b)
            case let (a?, nil): return a
            case let (nil, b?): return b
            case (nil, nil): return nil
            }
        }
    }

    /// The node for daemon `layout`, with each pane's tabs from `tabs`.
    /// A stack (panes over each other in one slot) becomes equal vertical
    /// splits; an unknown node or a pane without tabs is left out.
    static func capture(_ layout: LayoutNode, tabs: (PaneID) -> [WorkspaceBlueprint.Tab]) -> Self? {
        switch layout {
        case .leaf(let pane):
            let found = tabs(pane)
            return found.isEmpty ? nil : .pane(found)
        case .split(_, let direction, let ratio, let a, let b):
            switch (capture(a, tabs: tabs), capture(b, tabs: tabs)) {
            case let (a?, b?): return .split(direction: direction, ratio: ratio, a: a, b: b)
            case let (a?, nil): return a
            case let (nil, b?): return b
            case (nil, nil): return nil
            }
        case .stack(let panes, _):
            let nodes = panes.compactMap { capture(.leaf($0), tabs: tabs) }
            guard var node = nodes.last else { return nil }
            // Right-fold so every pane gets an equal share.
            for (offset, next) in nodes.dropLast().reversed().enumerated() {
                node = .split(direction: .down, ratio: 1 / Double(offset + 2), a: next, b: node)
            }
            return node
        case .unknown:
            return nil
        }
    }
}

@MainActor
extension WorkspaceBlueprint {
    /// The blueprint of `workspace` as the store mirrors it now.
    init(_ workspace: WorkspaceModel) {
        name = workspace.displayName
        color = workspace.color
        icon = workspace.icon
        screens = workspace.screens.compactMap { screen in
            let tabs: (PaneID) -> [Tab] = { handle in
                (screen.pane(handle)?.tabs ?? []).compactMap { tab in
                    switch tab.kind {
                    case .pty: .terminal(cwd: tab.cwd)
                    case .browser: tab.url.map {
                        .browser(url: $0, engine: tab.browserEngine.flatMap(BrowserEngine.init(rawValue:)), profile: tab.snapshot.browserProfileID)
                    }
                    // A remote reference or a conversation is not re-created on duplicate.
                    case .remoteTerminal, .conversation, .other: nil
                    }
                }
            }
            let columns: [Column] = screen.columns.isEmpty
                ? [Node.capture(screen.layout, tabs: tabs).map { Column(width: nil, root: $0) }].compactMap { $0 }
                : screen.columns.compactMap { column in Node.capture(column.layout, tabs: tabs).map { Column(width: column.width, root: $0) } }
            return columns.isEmpty ? nil : Screen(name: screen.name, columns: columns)
        }
    }
}
