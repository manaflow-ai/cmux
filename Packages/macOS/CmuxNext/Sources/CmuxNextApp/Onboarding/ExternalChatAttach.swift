import AppKit
import CmuxNextActions
import CmuxNextAgentPane
import CmuxNextControl
import CmuxNextSettings

/// The one route that puts files from another app into an agent chat's composer as an unsent draft
/// (Leo, 2026-11-08, ask-a862e90c70: "holy fuck. those NEED to be written down and FIXED and
/// IMPROVED", on a screenshot that could not reach a chat from another app). Its doors: an image
/// opened with cmux or dropped on its Dock icon (``ExternalOpenRouter``'s `.attachImages`), the
/// Send to cmux Chat service (``CmuxServicesProvider``), and later a capture shortcut and the Share
/// menu, which call ``ExternalOpenController/attachToChat(_:from:)``.
///
/// The files go to the focused agent chat of the window, else the one focused most recently there,
/// else a new agent chat (the pane's New Agent Chat); that chat's composer takes the keyboard.
/// `chat.composer.get` reads back what the composer of the chat that last took files holds.
@MainActor
final class ExternalChatAttach {
    unowned let services: AppServices
    /// The chat that last took files: `chat.composer.get` reads it back.
    private weak var last: AgentPaneView?
    /// Files waiting for the new chat opened for them: more that come meanwhile join them, rather
    /// than open a second chat. One older than ``openingLimit`` is a chat that never came.
    private var opening: (urls: [URL], claimed: String?, since: ContinuousClock.Instant)?
    static let openingLimit: Duration = .seconds(10)

    init(services: AppServices) {
        self.services = services
    }

    /// Puts `urls` into the composer of the chat ``target(near:)`` picks in `pane`'s workspace, or of
    /// a new agent chat in `pane`. `claimed`: the bundle id of the app they came from, when known.
    func attach(_ urls: [URL], claimed: String?, in pane: PaneController) {
        guard !urls.isEmpty else { return }
        if let waiting = opening, ContinuousClock.now - waiting.since < Self.openingLimit {
            opening = (waiting.urls + urls, waiting.claimed ?? claimed, waiting.since)
            return
        }
        opening = nil
        if let (chatPane, view) = Self.target(near: pane) {
            deliver(urls, claimed: claimed, to: view, in: chatPane)
            return
        }
        opening = (urls, claimed, .now)
        let opened = pane.openAgentTab(seed: pane.agentSeedFromSelectedTab()) { [weak self, weak pane] key in
            guard let self, let pane, let waiting = opening else { return }
            opening = nil
            let tabs = services.agentTabs, machine = pane.daemon.machineID
            guard let view = tabs.existingView(key, machine: machine) ?? tabs.view(for: key, machine: machine) else {
                services.daemon.logger.error("attach to a new chat: its page was not made")
                return
            }
            deliver(waiting.urls, claimed: waiting.claimed, to: view, in: pane)
        }
        if !opened { opening = nil }
    }

    /// The agent chat files from another app go to: `pane`'s when it shows one, else the one shown in
    /// the workspace's most recently focused pane. A New Tab page is no chat.
    static func target(near pane: PaneController) -> (PaneController, AgentPaneView)? {
        let recent = pane.workspace.map { content in content.recentPanes.compactMap { content.panes[$0] } } ?? []
        for candidate in [pane] + recent {
            if case .agent(let view) = candidate.currentContent, view.model.newTab == nil { return (candidate, view) }
        }
        return nil
    }

    private func deliver(_ urls: [URL], claimed: String?, to view: AgentPaneView, in pane: PaneController) {
        last = view
        if let key = pane.currentTabKey {
            let machine = pane.daemon.isLocal ? nil : pane.daemon.machineID
            _ = services.registry.perform("tab.focus", invocation: ActionInvocation(target: ActionTargetRef(kind: .tab, id: key), origin: .user).onMachine(machine))
        }
        view.attachExternal(urls, claimed: claimed)
        view.focusComposer()
    }

    /// `chat.composer.get`: what the composer holds of the chat that last took files from another
    /// app, else of the focused agent chat: `{session, attachments: [{name, mimeType, bytes, source}],
    /// text}`, `session` null for a chat not started yet, and all empty without a chat.
    func composerState() async -> JSONValue {
        let focused = services.windows.active?.focusedPane.flatMap { Self.target(near: $0)?.1 }
        guard let view = last ?? focused else { return Self.noComposer }
        return await view.composerReadback()
    }

    nonisolated static let noComposer: JSONValue = .object(["session": .null, "attachments": .array([]), "text": .string("")])

    /// The control method (`cmux app call chat.composer.get '{}'`), for tests and probes.
    func controlMethods() -> [ControlMethod] {
        [.async("chat.composer.get") { [weak self] _ in await self?.composerState() ?? Self.noComposer }]
    }
}
