public import AppKit
public import CmuxNextActions
public import CmuxNextSidebar

/// The rows of a workspace row's drive indicator menu (``SidebarView/driveMenuItem``), each a registered
/// action, so the menu runs the same path as the action's other entrypoints: Go to is Show Tab
/// (`tab.focus`, the palette's and `cmux tab <id> focus`'s), a Computer Use Stop is Stop Computer Use
/// (`computerUseStop`, the File menu's and the CLI's) on the agent's terminals, and a browsing chat's Stop
/// is Stop Agent Turn (`agentPane.stopTurn`) on its tab.
///
/// ```swift
/// sidebarView.driveMenuItem = SidebarDriveMenuItems(registry: registry, terminals: { _ in [] }).menuItem
/// ```
@MainActor
public struct SidebarDriveMenuItems {
    private let registry: ActionRegistry
    private let terminals: @MainActor (TabID) -> [String]

    /// - Parameter registry: The registry whose actions the rows run.
    /// - Parameter terminals: The terminal ids of the agent's tab; Stop Computer Use stops the session one
    ///   of them started first (`ComputerUseLiveSession.pick`), else the newest.
    public init(registry: ActionRegistry, terminals: @escaping @MainActor (TabID) -> [String]) {
        self.registry = registry
        self.terminals = terminals
    }

    /// The registry's row for `command`, titled `title`; nil when the registry has none.
    public func item(_ command: SidebarDriveCommand, title: String) -> NSMenuItem? {
        switch command {
        case .goTo(let tab):
            return registry.makeArgumentMenuItem(for: "tab.focus", target: ActionTargetRef(kind: .tab, id: tab.rawValue), title: title)
        case .stop(let tab, .browser):
            // The chat's own menu context: its tab is the agent chat the action stops.
            return registry.makeContextMenuItem(for: "agentPane.stopTurn", in: .agentChat,
                                                target: ActionTargetRef(kind: .tab, id: tab.rawValue), title: title)
        case .stop(let tab, .screen):
            let arguments: [String: ActionValue] = ["terminals": .string(terminals(tab).joined(separator: ","))]
            return registry.makeArgumentMenuItem(for: "computerUseStop", arguments: arguments, title: title)
        }
    }

    /// ``item(_:title:)`` in the shape ``SidebarView/driveMenuItem`` takes.
    public var menuItem: (WorkspaceID, SidebarDriveCommand, String) -> NSMenuItem? {
        { _, command, title in item(command, title: title) }
    }
}
