public import Foundation

/// One candidate of Search Tabs: an open tab anywhere (every kind, pane,
/// workspace, window and machine) or a recently closed one. A value
/// snapshot the App makes from its mirror when the page opens; nothing here
/// is a second copy of daemon state.
public nonisolated struct TabSearchEntry: Sendable, Hashable, Identifiable {
    public enum Kind: String, Sendable, Hashable {
        case terminal
        case browser
        /// A terminal on another session (remote-terminal tab).
        case remoteTerminal
        case other
    }

    public enum State: Sendable, Hashable {
        /// `lastActive`: when the user last settled on the tab (the location
        /// trail), nil when never.
        case open(isCurrent: Bool, lastActive: Date?)
        case closed(closedAt: Date)
    }

    /// The tab id for an open tab; the closed-items record id for a closed one.
    public var id: String
    public var kind: Kind
    public var title: String
    public var url: String?
    public var cwd: String?
    /// What runs in the tab, when known (an agent such as `claude`).
    public var process: String?
    public var workspaceID: String?
    public var workspaceTitle: String?
    /// The window that shows the tab's workspace, when there are several.
    public var windowTitle: String?
    /// The machine name of a tab on another machine; nil on this Mac.
    public var machine: String?
    /// Position in the layout (window, workspace, screen, pane, strip):
    /// the order of the grouped layout and the tie-break everywhere.
    public var order: Int
    public var state: State
    /// False when the tab cannot be focused or reopened now (its machine is
    /// offline). The row stays visible, dimmed.
    public var isAvailable: Bool
    /// SF Symbol override for `.other` kinds.
    public var symbol: String?

    public init(id: String, kind: Kind, title: String, url: String? = nil, cwd: String? = nil, process: String? = nil,
                workspaceID: String? = nil, workspaceTitle: String? = nil, windowTitle: String? = nil, machine: String? = nil,
                order: Int = 0, state: State, isAvailable: Bool = true, symbol: String? = nil) {
        self.id = id
        self.kind = kind
        self.title = title
        self.url = url
        self.cwd = cwd
        self.process = process
        self.workspaceID = workspaceID
        self.workspaceTitle = workspaceTitle
        self.windowTitle = windowTitle
        self.machine = machine
        self.order = order
        self.state = state
        self.isAvailable = isAvailable
        self.symbol = symbol
    }

    public var isClosed: Bool {
        if case .closed = state { return true }
        return false
    }

    public var isCurrent: Bool {
        if case .open(let current, _) = state { return current }
        return false
    }

    /// When the tab was last used: last active for an open tab, the close
    /// time for a closed one.
    public var lastUsed: Date? {
        switch state {
        case .open(_, let lastActive): lastActive
        case .closed(let closedAt): closedAt
        }
    }

    /// The SF Symbol of the row.
    public var rowSymbol: String {
        if let symbol { return symbol }
        switch kind {
        case .terminal: return "terminal"
        case .browser: return "globe"
        case .remoteTerminal: return "network"
        case .other: return "square.dashed"
        }
    }

    /// The URL's host without `www.` (`github.com`), else nil.
    public var host: String? {
        guard let url, let host = URL(string: url)?.host(), !host.isEmpty else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}
