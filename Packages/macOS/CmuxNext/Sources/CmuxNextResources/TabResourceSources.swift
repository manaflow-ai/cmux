import Foundation

/// What a tab renders with.
public enum TabResourceKind: String, Sendable, Hashable {
    case terminal
    case chromium
    case webkit
    case other
}

/// The processes one tab owns, resolved when a sample is taken.
public struct TabResourceSources: Sendable, Equatable {
    public var tabID: String
    public var title: String
    public var kind: TabResourceKind
    /// Processes that do this tab's work: a terminal's host, shell and
    /// every descendant; a Chromium tab's renderers; a WebKit tab's
    /// WebContent process. A process may appear in several tabs (Chromium
    /// can put two tabs of one site in one renderer); totals count it once.
    public var processes: [ProcessKey]
    /// App-side memory that has no process of its own, for example a
    /// mounted Ghostty surface. An estimate; never counted twice.
    public var estimatedAppBytes: UInt64
    /// False when the owner of the numbers cannot report them (a daemon
    /// without `terminal-resources-v1`, a page that is not loaded).
    public var available: Bool

    public init(tabID: String, title: String, kind: TabResourceKind, processes: [ProcessKey],
                estimatedAppBytes: UInt64 = 0, available: Bool = true) {
        self.tabID = tabID
        self.title = title
        self.kind = kind
        self.processes = processes
        self.estimatedAppBytes = estimatedAppBytes
        self.available = available
    }
}

/// What a hover card or `resources` call measures.
public enum ResourceTarget: Sendable, Hashable {
    case tab(String)
    case workspace(String)
}
