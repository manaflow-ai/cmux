import Foundation

/// What a Task Manager row's process does for cmux, in display order.
public enum TaskManagerRowKind: Int, Sendable, Hashable, CaseIterable, Comparable {
    /// The cmux app process (window chrome, Ghostty, Chromium's browser process).
    case app
    /// A cmux-tui daemon that owns the terminals and the layout.
    case daemon
    /// Chromium's GPU process.
    case gpu
    /// Chromium's network service.
    case network
    /// Other Chromium utility processes (storage, audio, ...).
    case utility
    /// Chromium extension renderers.
    case extensions
    /// A terminal tab's terminal host, shell or one of its descendants.
    case terminal
    /// A Chromium renderer of one or more browser tabs.
    case renderer
    /// The WebKit WebContent process of a page or an agent chat.
    case webContent
    /// A process of a tab of another kind.
    case other

    public static func < (lhs: TaskManagerRowKind, rhs: TaskManagerRowKind) -> Bool { lhs.rawValue < rhs.rawValue }

    /// The localized name of the kind, for rows that belong to no tab.
    public var title: String {
        switch self {
        case .app: Strings.role(.app)
        case .daemon: TaskManagerStrings.daemon
        case .gpu: Strings.role(.gpu)
        case .network: Strings.role(.network)
        case .utility: Strings.role(.utility)
        case .extensions: Strings.role(.extensions)
        case .terminal: TaskManagerStrings.terminal
        case .renderer: TaskManagerStrings.renderer
        case .webContent: TaskManagerStrings.webContent
        case .other: TaskManagerStrings.other
        }
    }

    init(_ role: SharedRole) {
        switch role {
        case .app: self = .app
        case .gpu: self = .gpu
        case .network: self = .network
        case .utility: self = .utility
        case .extensions: self = .extensions
        }
    }

    init(_ kind: TabResourceKind) {
        switch kind {
        case .terminal: self = .terminal
        case .chromium: self = .renderer
        case .webkit: self = .webContent
        case .other: self = .other
        }
    }
}
