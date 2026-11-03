public import CmuxNextActions
public import CmuxNextSidebar
import Foundation

/// Reveal Workspace in Sidebar and Reveal and Focus Workspace in Sidebar (Lawrence msg 20167: "we need a cmd shift p
/// command like focus in sidebar/scroll to in sidebar which is im in a workspaces and i want to see it in sidebar so
/// i know where it is"). The palette, the workspace row's right-click menu, a shortcut bound in cmux.json or Settings,
/// and `cmux action run` all run these two binds, and both run ``SidebarView/revealWorkspace(_:)``: one path.
///
/// Reveal leaves keyboard focus where it is. Reveal and Focus then runs `focusSidebar`, the existing Focus Sidebar
/// action, so the workspace list takes the keyboard at the current workspace's row as it does there.
///
/// ```swift
/// SidebarRevealActions(workspace: { try? host.workspaceID($0) }, sidebar: { window?.sidebarView }).bind(into: registry)
/// ```
@MainActor
public struct SidebarRevealActions {
    /// Reveal Workspace in Sidebar: the targeted workspace (a row's menu), else the window's current one.
    public static let reveal: ActionID = "sidebar.revealWorkspace"
    /// Reveal and Focus Workspace in Sidebar: the window's current workspace, then the list takes the keyboard.
    public static let revealAndFocus: ActionID = "sidebar.revealAndFocusWorkspace"
    /// The action that moves keyboard focus to the workspace list (the App binds it).
    static let focusSidebar: ActionID = "focusSidebar"

    private let workspace: @MainActor (ActionInvocation) -> String?
    private let sidebar: @MainActor () -> SidebarView?

    /// - Parameters:
    ///   - workspace: The id of the workspace the invocation targets; nil when it targets none (the window's current
    ///     workspace is revealed then).
    ///   - sidebar: The active window's sidebar; nil when no window is open.
    public init(workspace: @escaping @MainActor (ActionInvocation) -> String?, sidebar: @escaping @MainActor () -> SidebarView?) {
        self.workspace = workspace
        self.sidebar = sidebar
    }

    /// Binds both actions into `registry`.
    public func bind(into registry: ActionRegistry) {
        let run = self.run
        registry.bindEffect(Self.reveal) { invocation in
            run(invocation, true).map { ActionEffect.refused($0) } ?? .done
        }
        registry.bindEffect(Self.revealAndFocus) { [weak registry] invocation in
            if let refusal = run(invocation, false) { return .refused(refusal) }
            _ = registry?.perform(Self.focusSidebar, invocation: invocation)
            return .done
        }
    }

    /// Reveals the invocation's workspace (`targeted`) or the window's current one; the refusal text when it cannot.
    private func run(_ invocation: ActionInvocation, _ targeted: Bool) -> String? {
        guard let sidebar = sidebar() else { return Self.text("reveal.refusal.noWindow", "no window is open") }
        let id = (targeted && invocation.target != nil ? workspace(invocation).map(WorkspaceID.init) : nil)
            ?? sidebar.model.activeWorkspaceID
        guard let id, sidebar.revealWorkspace(id) else {
            return Self.text("reveal.refusal.notListed", "this window's sidebar does not list the workspace")
        }
        return nil
    }

    private static func text(_ key: StaticString, _ value: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: value, table: "SidebarReveal", bundle: .module)
    }
}
