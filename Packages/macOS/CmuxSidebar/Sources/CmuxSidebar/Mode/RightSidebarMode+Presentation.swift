import Foundation

extension RightSidebarMode {
    /// The SF Symbol name used to represent this mode in the right-sidebar mode
    /// picker. Pure SF Symbol identifiers with no AppKit or localization coupling.
    public var symbolName: String {
        switch self {
        case .files: return "folder"
        case .find: return "magnifyingglass"
        case .sessions: return "books.vertical"
        case .feed: return "dot.radiowaves.left.and.right"
        case .dock: return "dock.rectangle"
        }
    }
}

extension RightSidebarMode {
    /// The modes that can be detached from the sidebar and opened as a standalone
    /// pane, in declaration order.
    public static let paneModes: [RightSidebarMode] = [.files, .find, .sessions]

    /// Whether this mode can be opened as a standalone pane.
    public var canOpenAsPane: Bool {
        Self.paneModes.contains(self)
    }
}
