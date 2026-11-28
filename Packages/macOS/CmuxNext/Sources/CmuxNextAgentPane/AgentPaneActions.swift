public import CmuxNextActions
public import Foundation

// The agent pane's actions. Descriptors live in CmuxNextActions
// (`ActionCatalog+Agents`), so the palette, menus, the tab strip's new-tab
// menu, shortcuts (`shortcuts.palette.newAgentChat`) and the CLI
// (`cmux agent new-chat`) all come from the registry; this binds handlers.

extension ActionID {
    /// New Agent Chat: opens an agent tab.
    public static let newAgentChat: ActionID = "palette.newAgentChat"
    /// Show ACP Inspector: toggles the agent pane's ACP inspector
    /// (`AgentPaneView.toggleInspector`).
    public static let toggleAcpInspector: ActionID = "agentPane.toggleInspector"
    /// Open File: a file in a tab of the pane or in the text editor
    /// (`AgentPaneFileOpening`).
    public static let fileOpen: ActionID = "file.open"
    /// New Browser Tab, with `url` to open a page in it.
    public static let openBrowser: ActionID = "openBrowser"
}

extension ActionRegistry {
    /// Binds every agent pane action. `openNewChat` opens an agent tab in
    /// the invocation's pane (the focused pane when it has no target).
    /// Returns false when a descriptor is missing from the catalog.
    @discardableResult
    public func bindAgentPane(openNewChat: @escaping @MainActor (ActionInvocation) -> Void) -> Bool {
        bind(.newAgentChat, invoke: openNewChat)
    }

    /// Binds Show ACP Inspector. `toggle` toggles the inspector of the agent
    /// tab shown in the invocation's pane (the focused pane when it has no
    /// target). Returns false when the descriptor is missing from the catalog.
    @discardableResult
    public func bindAgentPaneInspector(toggle: @escaping @MainActor (ActionInvocation) -> Void) -> Bool {
        bind(.toggleAcpInspector, invoke: { [weak self] invocation in
            guard ActionRunScope.viewChangeAllowed() else {
                self?.refuse(AgentPaneView.inspectorNeedsFocus)
                return
            }
            toggle(invocation)
        })
    }
}

extension ActionRegistry {
    /// Opens an agent tab's changed file through `file.open` on `pane`, the
    /// path the palette and `cmux file open` take. False when the handler
    /// refused, so the page shows its notice instead of the app's beep; an
    /// editor that fails after it starts opening is not reported back.
    @discardableResult
    public func openAgentFile(path: String, target: AgentPaneFileTarget, pane: String) -> Bool {
        let invocation = ActionInvocation(
            target: ActionTargetRef(kind: .pane, id: pane),
            arguments: ["path": .string(path), "where": .string(target.rawValue)]
        )
        var performed = false
        let refusal = reportingRefusal { performed = perform(.fileOpen, invocation: invocation) }
        return performed && refusal == nil
    }

    /// Opens a turn's local web page (its preview card) in a new browser tab
    /// of `pane` through `openBrowser`, the path the tab strip and palette
    /// take. False when the handler refused.
    @discardableResult
    public func openAgentPreview(_ url: URL, pane: String) -> Bool {
        let invocation = ActionInvocation(
            target: ActionTargetRef(kind: .pane, id: pane),
            arguments: ["url": .string(url.absoluteString)]
        )
        var performed = false
        let refusal = reportingRefusal { performed = perform(.openBrowser, invocation: invocation) }
        return performed && refusal == nil
    }
}
