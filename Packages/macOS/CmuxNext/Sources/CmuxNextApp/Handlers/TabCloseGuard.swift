import AppKit
import CmuxNextActions
import CmuxNextBridge
import CmuxNextBrowser
import CmuxNextFocus
import CmuxNextDaemon
import CmuxNextSettings
import CmuxNextTabs

/// The one question a user's tab close can ask (#17501, as classic #17430).
/// A closed terminal ends after the daemon's reap grace, so a close asks
/// only while a closing terminal is doing work: an agent at work in it
/// ("Claude is still working.", `app.warnBeforeClosingAgentSession`), else a
/// foreground program (`app.warnBeforeClosingTab`). Idle terminals, browser
/// tabs, New Tab pages and agent chats (their session keeps running in
/// acpmux) close at once, and the undo toast brings them back. Automation
/// never asks.
@MainActor
enum TabCloseGuard {
    enum Warning: Equatable {
        /// The agent working in a closing terminal (the first, if several).
        case agent(String)
        /// Foreground programs in the closing terminals, unique and sorted.
        case programs([String])
    }

    /// Runs `close` at once, or after the person confirms the question.
    /// `close` gets what the question asked the terminals, so the close's undo
    /// toast decision does not ask them again (one daemon read per Cmd-W, not two).
    static func close(_ tabs: [TabModel], on daemon: DaemonService, services: AppServices, window: NSWindow?,
                      close: @escaping @MainActor (_ asked: RunningPrograms) -> Void) {
        guard CloseUndoToasts.isUserClose, window != nil, asks(tabs, services: services) else { return close([:]) }
        // A second close of tabs this close is already asking about (a double click on a close button) is the same close.
        guard tabs.contains(where: { !asking.contains($0.id) }) else { return }
        let ids = Set(tabs.map(\.id)), terminals = askedTerminals(closing: tabs, services: services)
        // No terminal to ask (the program warning is off, or only agents work): the close, or the agent's
        // question, in the person's own turn.
        guard !terminals.isEmpty else { return answer(tabs, ids: ids, asked: [:], window: window, services: services, close: close) }
        asking.formUnion(ids)
        reading.formUnion(ids)
        // Only the daemon's read is awaited, off main; the close or the question is the person's completion, one
        // userBlocking task that answers the press.
        let end = services.registry.completion(on: services.mainWork)
        end.start {
            let asked = await DestructiveConfirmation.runningPrograms(bySurface: terminals, on: daemon)
            end.post(owner: "TabCloseGuard.close", answering: true) {
                reading.subtract(ids)
                answer(tabs, ids: ids, asked: asked, window: window, services: services, close: close)
            }
        }
    }

    /// Closes `tabs` now, or asks the question for them and closes on the person's yes. `asked`: what the
    /// terminals answered (``askedTerminals(closing:services:)``).
    private static func answer(_ tabs: [TabModel], ids: Set<String>, asked: RunningPrograms, window: NSWindow?, services: AppServices,
                               close: @escaping @MainActor (_ asked: RunningPrograms) -> Void) {
        guard let prompt = question(closing: tabs, asked: asked, services: services) else {
            asking.subtract(ids)
            return close(asked)
        }
        asking.formUnion(ids)
        DestructiveConfirmation.present(prompt, in: window, settings: services.settings) {
            asking.subtract(ids)
            if $0 { close(asked) }
        }
    }

    /// The tabs whose close is still asking (the daemon's read, then the question): they
    /// stay in their strip, selected, until it answers; a second close of them is the same close.
    private(set) static var asking: Set<String> = []
    /// Those still in the daemon's read: a quick next Cmd-W skips them. Once the question
    /// shows, a Cmd-W behind it closes nothing until the person answers.
    private(set) static var reading: Set<String> = []

    /// The tab a user's Cmd-W on `id` closes: `id`, or while `id`'s close is still under way
    /// (`closing`: the daemon's read, or its page deciding), the tab selected once it closes (the
    /// next not closing, else the previous), so N quick presses close N tabs (Leo 2026-10-21).
    /// Nil when every other tab is closing too.
    static func cmdWTarget(_ id: StripTabID, in strip: TabStripModel, closing: (StripTabID) -> Bool) -> StripTabID? {
        guard closing(id) else { return id }
        let ordered = strip.orderedTabs
        guard let index = ordered.firstIndex(where: { $0.id == id }) else { return id }
        func open(_ tab: TabItem) -> Bool { !closing(tab.id) && !asking.contains(tab.id.rawValue) && tab.isClosable }
        return (ordered[(index + 1)...].first(where: open) ?? ordered[..<index].last(where: open))?.id
    }

    /// ``cmdWTarget(_:in:closing:)`` for `pane`: its tabs still in the daemon's read, or whose page
    /// decides its close (``PageClosingTabs``), are closing.
    static func cmdWTarget(_ id: StripTabID, in pane: PaneController) -> StripTabID? {
        let pages = pane.services.closedTabs?.undoToasts.pageClosing
        return cmdWTarget(id, in: pane.stripModel) { tab in
            reading.contains(tab.rawValue) || pages?.contains(tab.rawValue) == true
        }
    }

    /// A Close Tab press as ``PaneCloseAim`` reads it: the input event AppKit is dispatching (its
    /// time and repeat flag), else the time of the press that started a gated run, else now.
    static func press(_ ctx: AppActionContext, _ invocation: ActionInvocation) -> PaneCloseAim.Press {
        let event = ctx.registry.dispatchingInputEvent()
        switch event?.type {
        case .keyDown?:
            return .init(time: event?.timestamp ?? 0, isKey: true, isRepeat: event?.isARepeat == true)
        case .leftMouseDown?, .leftMouseUp?, .rightMouseDown?, .rightMouseUp?, .otherMouseDown?, .otherMouseUp?, .keyUp?:
            return .init(time: event?.timestamp ?? 0, isKey: false, isRepeat: false)
        default:
            return .init(time: invocation.inputTimestamp ?? ProcessInfo.processInfo.systemUptime, isKey: false, isRepeat: false)
        }
    }

    /// Whether closing `closing` leaves `pane` with no tab (tabs whose close is still asking count as closed).
    static func empties(_ pane: PaneController, closing: [StripTabID]) -> Bool {
        let pages = pane.services.closedTabs?.undoToasts.pageClosing
        return pane.orderedIDs.allSatisfy { closing.contains($0) || asking.contains($0.rawValue) || pages?.contains($0.rawValue) == true }
    }

    /// Whether closing `tabs` can ask at all (a live terminal and a warning
    /// setting on), before any terminal is asked what it runs.
    static func asks(_ tabs: [TabModel], services: AppServices) -> Bool {
        let snapshot = services.settings?.snapshot
        let warnTab = snapshot?.warnBeforeClosingTab ?? CmuxConfigSnapshot.closeWarningFallback
        let warnAgent = snapshot?.warnBeforeClosingAgentSession ?? CmuxConfigSnapshot.closeWarningFallback
        return (warnTab || warnAgent) && tabs.contains { $0.kind == .pty && !$0.dead }
    }

    /// The question for closing `tabs` (a tab, a selection, a tab group), or
    /// nil to close at once: only a working agent or a foreground program asks.
    static func prompt(closing tabs: [TabModel], on daemon: DaemonService, services: AppServices) async -> DestructiveConfirmation.Prompt? {
        await promptAndAnswers(closing: tabs, on: daemon, services: services).prompt
    }

    /// `prompt`, plus each terminal it asked and its answer.
    static func promptAndAnswers(closing tabs: [TabModel], on daemon: DaemonService,
                                 services: AppServices) async -> (prompt: DestructiveConfirmation.Prompt?, asked: RunningPrograms) {
        let asked = await askedPrograms(closing: tabs, on: daemon, services: services)
        return (question(closing: tabs, asked: asked, services: services), asked)
    }

    /// The closing terminals the question asks about, each with its foreground program: the terminals
    /// without a working agent (an agent's terminal is that agent's question), when `app.warnBeforeClosingTab` is on.
    static func askedPrograms(closing tabs: [TabModel], on daemon: DaemonService, services: AppServices) async -> RunningPrograms {
        let others = askedTerminals(closing: tabs, services: services)
        guard !others.isEmpty else { return [:] }
        return await DestructiveConfirmation.runningPrograms(bySurface: others, on: daemon)
    }

    /// The closing terminals ``askedPrograms(closing:on:services:)`` asks: the live ones without a working agent,
    /// when `app.warnBeforeClosingTab` is on. Empty: the close needs no daemon read.
    static func askedTerminals(closing tabs: [TabModel], services: AppServices) -> [TabModel] {
        guard services.settings?.snapshot.warnBeforeClosingTab ?? CmuxConfigSnapshot.closeWarningFallback else { return [] }
        return tabs.filter { $0.kind == .pty && !$0.dead && workingAgent($0) == nil }
    }

    /// The question for closing `tabs` once the terminals answered (`asked`), or nil to close at once.
    static func question(closing tabs: [TabModel], asked: RunningPrograms, services: AppServices) -> DestructiveConfirmation.Prompt? {
        let snapshot = services.settings?.snapshot
        let warnTab = snapshot?.warnBeforeClosingTab ?? CmuxConfigSnapshot.closeWarningFallback
        let warnAgent = snapshot?.warnBeforeClosingAgentSession ?? CmuxConfigSnapshot.closeWarningFallback
        let terminals = tabs.filter { $0.kind == .pty && !$0.dead }
        guard warnTab || warnAgent, !terminals.isEmpty else { return nil }
        let agents = terminals.compactMap(workingAgent)
        return warning(agents: agents, programs: asked.programNames, warnTab: warnTab, warnAgent: warnAgent)
            .map { prompt($0, closing: tabs) }
    }

    /// The question for these closing terminals, or nil to close at once.
    static func warning(agents: [String], programs: [String], warnTab: Bool, warnAgent: Bool) -> Warning? {
        if warnAgent, let agent = agents.first { return .agent(agent) }
        if warnTab, !programs.isEmpty { return .programs(programs) }
        return nil
    }

    static func prompt(_ warning: Warning, closing tabs: [TabModel]) -> DestructiveConfirmation.Prompt {
        let title = tabs.count == 1 ? ConfirmationStrings.closeTitle(tabs[0].title) : ConfirmationStrings.closeTabsTitle(tabs.count)
        switch warning {
        case .agent(let agent):
            return .init(title: title, body: ConfirmationStrings.agentStillWorking(agent),
                         button: ConfirmationStrings.close, suppresses: CmuxConfigSnapshot.warnBeforeClosingAgentSessionPath)
        case .programs(let programs):
            return .init(title: title,
                         body: ConfirmationStrings.stillRunning(programs.joined(separator: ", ")),
                         button: ConfirmationStrings.close, suppresses: CmuxConfigSnapshot.warnBeforeClosingTabPath)
        }
    }

    /// The display name of an agent working (or waiting on a permission
    /// answer) in `tab`'s terminal, else nil.
    static func workingAgent(_ tab: TabModel) -> String? {
        guard let status = tab.agent, status.state == .working || status.state == .blocked else { return nil }
        return displayName(status.agent)
    }

    /// "claude" reads "Claude"; an unnamed agent reads "The agent".
    static func displayName(_ agent: String?) -> String {
        guard let agent, let first = agent.first else { return ConfirmationStrings.theAgent }
        return first.uppercased() + agent.dropFirst()
    }
}

/// A person's Close Tab that empties the only pane of its workspace is that workspace's close (Lawrence 2026-10-28,
/// handoff/motion-cascade.md rules 1 and 2: "cmd w on last tab in workspace should ... just be same as cmd shift w
/// animation, not animate closing the tab first, then the workspace"). It runs Close Workspace for that row from the
/// press's turn: the row leaves, the selection moves and the next workspace shows, the daemon's close runs behind and
/// the workspace can be reopened. Before, the tab left, an empty pane stayed for a daemon round trip, and the empty-
/// workspace repair closed the workspace about three round trips later, ending its terminals.
///
/// A live terminal takes it too: Close Workspace asks what its tab close would ask (a working agent with
/// `app.warnBeforeClosingAgentSession`, a running program with `app.warnBeforeClosingTab`), after the row left; a no
/// lists the row again. A Chromium page keeps the tab close, which runs the page's `beforeunload` first (Close
/// Workspace does not yet), and so does a tab whose close is still asking or deciding.
@MainActor
extension TabCloseGuard {
    /// Closes `closing`'s workspace as Close Workspace does, when `closing` is every tab of the only pane of its
    /// workspace and nothing can hold the close back; marks `pane` emptied by `press`, so a held key's repeats close
    /// nothing in the next workspace (``PaneCloseAim``). A key repeat that would empty the workspace closes nothing and
    /// returns true. Returns false, doing nothing, otherwise (the caller closes the tabs: Home's, or a close that can be
    /// held back) or when Close Workspace does not run.
    static func closeWorkspaceIfEmptied(_ ctx: AppActionContext, emptying pane: PaneController, closing: [StripTabID],
                                        by press: PaneCloseAim.Press) -> Bool {
        guard let content = pane.workspace, closing.count == pane.orderedIDs.count,
              Set(closing) == Set(pane.orderedIDs),
              content.layoutModel.screens.reduce(0, { $0 + $1.layout.panes.count }) == 1 else { return false }
        // Key repeat never crosses into a workspace close (audit-findings-1 C, hold-shortcuts-ux.md): a held Cmd-W
        // stops at the last tab, whatever the tab is; only a new press closes the workspace. True: nothing closes.
        if press.isRepeat { return true }
        // Home cannot be closed (audit-findings-1 C): its tabs close as tabs.
        if isHome(content.workspace, ctx.services) { return false }
        guard closing.allSatisfy({ closesQuietly($0, in: pane) }) else { return false }
        guard ctx.registry.perform("closeWorkspace", invocation: ActionInvocation(closingRow: content.workspace.id)) else { return false }
        content.focus.noteEmptied(pane.paneKey, by: press)
        return true
    }

    /// Whether `workspace` is the store's home workspace (Home).
    static func isHome(_ workspace: WorkspaceModel, _ services: AppServices) -> Bool {
        workspace.kind == "home" || (workspace.resourceID != nil && workspace.resourceID == services.home.homeWorkspaceID)
    }

    /// Whether Close Workspace can take `id`'s close: it is not still asking or deciding, and no page decides it.
    private static func closesQuietly(_ id: StripTabID, in pane: PaneController) -> Bool {
        let key = id.rawValue
        if asking.contains(key) || pane.services.closedTabs?.undoToasts.pageClosing.contains(key) == true { return false }
        return !(pane.services.cache.browsers[key]?.tab is any BrowserUserClosing)
    }
}
