import Foundation

/// The kind icon used by an optional sidebar tab row.
public nonisolated enum SidebarTabKind: Hashable, Sendable, Codable {
    case terminal
    case browser
    case remoteTerminal
    case conversation
    case other(String)

    public var symbolName: String {
        switch self {
        case .terminal: "terminal"
        case .browser: "globe"
        case .remoteTerminal: "network"
        case .conversation: "bubble.left.and.bubble.right"
        case .other: "square"
        }
    }
}

/// A tab that can optionally be listed below its workspace.
public nonisolated struct SidebarTab: Identifiable, Hashable, Sendable {
    public var id: TabID
    public var title: String
    public var kind: SidebarTabKind
    public var isUnread: Bool

    public init(id: TabID, title: String, kind: SidebarTabKind = .terminal, isUnread: Bool = false) {
        self.id = id
        self.title = title
        self.kind = kind
        self.isUnread = isUnread
    }
}
