public import CmuxNextActions
import CmuxNextDesign
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
    /// Toggle the chat's floating Session Info panel through its header path.
    public static let toggleSessionInfo: ActionID = "agentPane.toggleSessionInfo"
    /// The page commands the palette runs (``AgentPageCommand``): `agentPane.<command>`.
    public init(_ command: AgentPageCommand) { self.init(rawValue: "agentPane.\(command.rawValue)") }
    /// Stop the focused agent chat's active turn through the page's composer path.
    public static let stopTurn: ActionID = "agentPane.stopTurn"
    /// Open File: a file in a tab of the pane or in the text editor
    /// (`AgentPaneFileOpening`).
    public static let fileOpen: ActionID = "file.open"
    /// New Browser Tab, with `url` to open a page in it.
    public static let openBrowser: ActionID = "openBrowser"
}

/// A chat control the native palette runs through the page's `command` bridge, by its name there.
/// The page lists the ones that apply to its chat now (`pane.commandAvailability`): Quick Chat's
/// panel has no tabs beside it, a remote chat's folder is not on this Mac, Preview needs the chat's
/// page or the preview it opened, Run in Background needs work in the foreground, and Session
/// Info's sections need rows.
public enum AgentPageCommand: String, CaseIterable, Sendable {
    case toggleFiles, togglePreview, toggleSideTabs
    case runInBackground, toggleQueueing, showSubagents, showBackgroundTasks
}

extension ActionRegistry {
    /// Binds every ``AgentPageCommand``. `available` is the page commands of the agent chat the
    /// invocation resolves to (its target, else the focused pane; nil when it is no agent chat: `run`
    /// refuses then). A command that page does not list refuses with the reason, checked for the
    /// run's own target (``ActionTargetReasons``; the palette row is disabled with it), and one run
    /// by automation without a focus request refuses too.
    @discardableResult
    public func bindAgentPageCommands(
        available: @escaping @MainActor (ActionInvocation) -> Set<String>?,
        run: @escaping @MainActor (AgentPageCommand, ActionInvocation) -> Void
    ) -> Bool {
        AgentPageCommand.allCases.map { command in
            let id = ActionID(command)
            let title = descriptor(for: id)?.title ?? command.rawValue
            let bound = bindEffect(id, effect: { invocation in
                guard ActionRunScope.viewChangeAllowed() else { return .refused(AgentPaneView.pageCommandNeedsFocus(title)) }
                run(command, invocation)
                return .done
            })
            let reason: @MainActor (ActionInvocation) -> String? = { invocation in
                guard let commands = available(invocation), !commands.contains(command.rawValue) else { return nil }
                return AgentPaneView.pageCommandUnavailable(title)
            }
            ActionTargetReasons.set(id, in: self, reason)
            // The palette runs on the focused chat: its row is disabled while that chat does not offer
            // it, with a subtitle that does not repeat the row's title.
            ActionTargetTitles.setPaletteReason(id, in: self) {
                reason(ActionInvocation()) == nil ? nil : AgentPaneView.pageCommandUnavailableHere
            }
            return bound
        }.allSatisfy(\.self)
    }

    /// Binds Session Info for the invocation's pane, focused when there is no target. With
    /// `agent.inspector` off the page has no Session Info, so the action refuses instead of
    /// reporting a toggle that changed nothing.
    @discardableResult
    public func bindAgentPaneSessionInfo(
        isOn: (@MainActor () -> Bool)? = nil,
        toggle: @escaping @MainActor (ActionInvocation) -> Void
    ) -> Bool {
        bindEffect(.toggleSessionInfo, effect: { invocation in
            guard isOn?() ?? AgentPaneTunables.sessionInfo.value else { return .refused(AgentPaneView.sessionInfoOff) }
            guard ActionRunScope.viewChangeAllowed() else {
                return .refused(AgentPaneView.sessionInfoNeedsFocus)
            }
            toggle(invocation)
            return .done
        })
    }

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
