import CmuxNextActions
import CmuxNextAgentPane
import CmuxNextCloud
import CmuxNextCompat
import CmuxNextDaemon
import Foundation

/// An agent's Move to Cloud (cmuxterm-hq#1874 slice 5): the agent runs the move's own action
/// (`cmux cloud move` from its shell, or the cmux MCP server's tool), and instead of moving, the app
/// asks the person in that agent's chat with a card (Move, Not now, Always), never a sheet. Only a
/// click there (a real gesture in the pane, ``AgentPaneToolCard``) starts the move, through the
/// one Move to Cloud action (``CloudMove``) on that chat, as a person's run. "Always" also records
/// the chat's synced folder: an agent's later ask from a chat in that folder starts the move at
/// once, with "Ask first next time" on its card to take that back.
///
/// An agent asks only for its own chat: the run's `caller.agent_session` names it, and a target of
/// another tab is refused. Like every caller rule this trusts the caller's claim; a process that
/// hides it is a person's run. Bring Back Local is never an agent's: its run is refused.
@MainActor
final class CloudMoveAsks {
    /// The card's owner in ``AgentToolCards``.
    static let owner = "cloudMove"

    private enum Answer: String {
        case move, notNow, always, askFirst, retry, dismiss
    }

    /// One chat's ask, by its tab.
    private struct Ask {
        var folder: String
        var always: Bool
    }

    private var asks: [String: Ask] = [:]
    private(set) var unfinishedOffer: Task<Void, Never>?
    /// Tabs whose card is the launch offer of an unfinished move: their Dismiss is remembered.
    private var offered: Set<String> = []
    private var dismissedMemory: [String: String] = [:]
    static let dismissedKey = "cmux.cloud.moveUnfinishedDismissed"
    /// Where "Always" folders are kept (``CloudMoveSetup/ledger``); nil keeps them in memory.
    var defaults: @MainActor () -> UserDefaults? = { nil }
    private var memory: Set<String> = []
    static let defaultsKey = "cmux.cloud.moveAlwaysFolders"

    /// Whether `invocation` is an agent's: a cmux MCP run, or one naming the agent chat that sent it.
    static func isAgent(_ invocation: ActionInvocation) -> Bool {
        invocation.origin == .mcp || invocation.callerAgentSession != nil
    }

    /// The agent's ask: checks the chat, then (in tracked work) shows the card in it, or moves at
    /// once from an "Always" folder. Throws before anything shows when the chat can't move.
    func ask(_ invocation: ActionInvocation, services: AppServices) throws {
        guard let session = invocation.callerAgentSession, let (tab, pane) = Self.chat(session, services: services) else {
            throw ActionFailure(message: CloudMoveAskStrings.notInChat)
        }
        if let target = invocation.target, target.kind != .tab || (target.id != tab.id && target.id != tab.resourceID?.rawValue) {
            throw ActionFailure(message: CloudMoveAskStrings.onlyOwnChat)
        }
        guard !CloudMove.hiddenMenuItems(tab).contains(CloudMove.action) else { throw ActionFailure(message: CloudMoveStrings.alreadyRemote) }
        let tabID = tab.id
        let work: ActionWork = Task { @MainActor [weak self] in
            let workspace = services.machines.local.store.workspace(containing: pane.handle)
            let chat = try? await CloudMove(services: services).chatFolder(tab: tab, workspace: workspace, session: session, invocation: ActionInvocation())
            guard let self else { return nil }
            guard let folder = chat.flatMap(CloudMoveFolder.init(chat:)) else { return ActionWorkFailure(CloudMoveStrings.noFolder) }
            guard !folder.isTooBroad else { return ActionWorkFailure(CloudMoveStrings.homeFolder) }
            // An ask already open or moving stays as it is, shown again (its chat's page may be a new one).
            if asks[tabID] != nil { return services.cloud.toolCards.reshow(tab: tabID) ? nil : ActionWorkFailure(CloudMoveAskStrings.noPage) }
            asks[tabID] = Ask(folder: folder.root, always: false)
            if alwaysFolders().contains(folder.root) {
                asks[tabID]?.always = true
                start(tabID, services: services)
            } else if !show(tabID, .ask, CloudMoveAskStrings.ask(Self.name(folder.root)), [.move, .notNow, .always], services: services) {
                asks[tabID] = nil
                return ActionWorkFailure(CloudMoveAskStrings.noPage)
            }
            return nil
        }
        services.registry.track(work)
    }

    /// After a launch: each chat tab whose move a quit, an update relaunch or a stop left unfinished
    /// (``CloudMoveRetries``) shows the move's card again, saying it didn't finish, with Retry, once
    /// this Mac's tree lists the tab (cx-rppd.16). Retry runs the move as the person's: ``CloudMove``
    /// finishes it on its pinned machine, or only opens the moved chat's tab there.
    func offerUnfinished(services: AppServices) {
        guard unfinishedOffer == nil else { return }
        // task-owner: one wait for this Mac's tree at launch, then one pass over the retries
        unfinishedOffer = Task { @MainActor [weak self, weak services] in
            for await loaded in ObservationStream({ [weak services] in services?.daemon.store.isLoaded ?? true }) where loaded {
                guard let self, let services else { return }
                let retries = services.cloud.moveRetries
                for tab in retries.tabs where asks[tab] == nil && services.locateTab(tab, onMachine: services.machines.local.machineID)?.0.agentSession != nil {
                    guard let retry = retries[tab], dismissed()[tab] != Self.fingerprint(retry) else { continue }
                    let text = switch retry {
                    case .show: CloudMoveStrings.unfinishedShow
                    case .move, .askFirst, .update: CloudMoveStrings.unfinishedMove
                    }
                    asks[tab] = Ask(folder: "", always: false)
                    offered.insert(tab)
                    show(tab, .failed, text, [.retry, .dismiss], services: services)
                }
                return
            }
        }
    }

    /// A move of chat tab `tab` started (a card's Move, or a person's palette, menu or CLI run).
    func moveStarted(_ tab: String, services: AppServices) {
        offered.remove(tab) // a card from here on is this move's, no longer the launch offer
        guard let ask = asks[tab] else { return }
        let text = ask.always ? CloudMoveAskStrings.movingAlways(Self.name(ask.folder)) : CloudMoveStrings.moving
        show(tab, .working, text, ask.always ? [.askFirst] : [], services: services)
    }

    /// The move of chat tab `tab` ended: its card goes when it moved, and says why when it stopped.
    func moveEnded(_ tab: String, failure: String?, services: AppServices) {
        guard asks[tab] != nil else { return }
        guard let failure else { return close(tab, services: services) }
        let retry = services.cloud.moveRetries[tab] != nil
        show(tab, .failed, failure, retry ? [.retry, .dismiss] : [.dismiss], services: services)
    }

    @discardableResult
    private func show(_ tab: String, _ state: AgentPaneToolCard.State, _ text: String, _ answers: [Answer], services: AppServices) -> Bool {
        let folder = asks[tab].map { Self.name($0.folder) } ?? ""
        let actions = answers.map { answer in
            AgentPaneToolCard.Action(id: answer.rawValue, title: Self.title(answer), hint: answer == .always ? CloudMoveAskStrings.alwaysHint(folder) : nil)
        }
        let card = AgentPaneToolCard(id: "cloud-move-" + tab, state: state, text: text, actions: actions)
        return services.cloud.toolCards.set([card], owner: Self.owner, tab: tab) { [weak self, weak services] _, action, _ in
            guard let self, let services, let answer = Answer(rawValue: action) else { return }
            self.answer(answer, tab: tab, services: services)
        }
    }

    private func answer(_ answer: Answer, tab: String, services: AppServices) {
        guard let ask = asks[tab] else { return }
        switch answer {
        case .move, .retry:
            start(tab, services: services)
        case .always:
            remember(ask.folder, true)
            asks[tab]?.always = true
            start(tab, services: services)
        case .askFirst:
            remember(ask.folder, false)
            asks[tab]?.always = false
            show(tab, .working, CloudMoveStrings.moving, [], services: services)
        case .notNow, .dismiss:
            // A launch offer the person dismissed stays dismissed for that same retry (a later stop asks again).
            if offered.contains(tab), let retry = services.cloud.moveRetries[tab] { rememberDismissed(tab, Self.fingerprint(retry)) }
            close(tab, services: services)
        }
    }

    /// The person's move of chat tab `tab`: the one Move to Cloud action, as a person runs it.
    private func start(_ tab: String, services: AppServices) {
        let registry = services.registry
        let invocation = ActionInvocation(target: ActionTargetRef(kind: .tab, id: tab), origin: .user)
        var ran = false
        let refusal = registry.capturingTypedRefusal { ran = registry.perform(CloudMove.action, invocation: invocation) }
        // A run that did nothing and said nothing (the action is off here) never leaves the card asking.
        if let reason = refusal?.reason ?? (ran ? nil : CloudMoveAskStrings.noMove) { show(tab, .failed, reason, [.dismiss], services: services) }
    }

    private func close(_ tab: String, services: AppServices) {
        asks[tab] = nil
        offered.remove(tab)
        services.cloud.toolCards.set([], owner: Self.owner, tab: tab) { _, _, _ in }
    }

    /// The local chat tab of agent session `session`, with its pane.
    private static func chat(_ session: String, services: AppServices) -> (TabModel, PaneModel)? {
        let tabs = services.agentTabs
        for pane in services.daemon.store.workspaces.flatMap(\.screens).flatMap(\.panes) {
            if let tab = pane.tabs.first(where: { (tabs.sessions[tabs.resolve($0.id)] ?? $0.agentSession?.session) == session }) { return (tab, pane) }
        }
        return nil
    }

    private static func name(_ folder: String) -> String { URL(fileURLWithPath: folder).lastPathComponent }

    private static func title(_ answer: Answer) -> String {
        switch answer {
        case .move: CloudMoveAskStrings.move
        case .notNow: CloudMoveAskStrings.notNow
        case .always: CloudMoveAskStrings.always
        case .askFirst: CloudMoveAskStrings.askFirst
        case .retry: CloudMoveStrings.retry
        case .dismiss: CloudMoveAskStrings.dismiss
        }
    }

    // MARK: "Always" folders

    /// A Retry as text: a launch offer Dismissed stays dismissed until its tab's Retry changes.
    static func fingerprint(_ retry: CloudMoveRetries.Retry) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return (try? encoder.encode(retry)).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }

    private func dismissed() -> [String: String] {
        guard let defaults = defaults() else { return dismissedMemory }
        return defaults.dictionary(forKey: Self.dismissedKey) as? [String: String] ?? [:]
    }

    private func rememberDismissed(_ tab: String, _ fingerprint: String) {
        var all = dismissed()
        all[tab] = fingerprint
        guard let defaults = defaults() else { return dismissedMemory = all }
        defaults.set(all, forKey: Self.dismissedKey)
    }

    private func alwaysFolders() -> Set<String> {
        guard let defaults = defaults() else { return memory }
        return Set(defaults.stringArray(forKey: Self.defaultsKey) ?? [])
    }

    private func remember(_ folder: String, _ always: Bool) {
        var folders = alwaysFolders()
        if always { folders.insert(folder) } else { folders.remove(folder) }
        guard let defaults = defaults() else { return memory = folders }
        defaults.set(folders.sorted(), forKey: Self.defaultsKey)
    }
}
