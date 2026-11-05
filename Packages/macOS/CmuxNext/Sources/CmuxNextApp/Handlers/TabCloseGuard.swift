import AppKit
import CmuxNextActions
import CmuxNextBridge
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
    /// Runs `close` at once, or after the person confirms the question.
    /// `close` gets what the question asked the terminals, so the close's undo
    /// toast decision does not ask them again (one daemon read per Cmd-W, not two).
    /// `parts`: the panes the tabs leave. When each keeps a tab or can show itself leaving (`showPaneClose`), the tabs (and a pane
    /// they empty) leave in this turn, terminals alive (`HiddenTabClose`); `close` gets that hide to lift as it closes (no flash).
    static func close(_ tabs: [TabModel], on daemon: DaemonService, services: AppServices, window: NSWindow?,
                      leaving parts: [(pane: PaneController, ids: [StripTabID])] = [],
                      close: @escaping @MainActor (_ asked: RunningPrograms, _ hidden: HiddenTabClose?) -> Void) {
        guard CloseUndoToasts.isUserClose, window != nil, asks(tabs, services: services) else { return close([:], nil) }
        // A second close of tabs this close is already asking about (a double click on a close button) is the same close.
        guard tabs.contains(where: { !asking.contains($0.id) }) else { return }
        let ids = Set(tabs.map(\.id))
        asking.formUnion(ids)
        reading.formUnion(ids)
        // The tabs leave now, their terminals alive: only the daemon's read below ends a process (SL-3; lead, #31875).
        // A page that decides its own close (beforeunload) is never hidden: it runs its decision after the read, in place.
        let decides = services.closedTabs?.undoToasts.pageDecidesClose ?? CloseUndoToasts.livePageDecidesClose
        // An emptied pane hides only if its layout shows it leaving (never the screen's last) and holds no page (asking starts its close).
        let emptied = parts.map { part in empties(part.pane, closing: part.ids) }
        let hides = !parts.isEmpty && zip(parts, emptied).allSatisfy { part, emptied in part.pane.daemon === daemon
            && (!emptied || (part.pane.workspace?.layoutModel.canShowPaneClose(part.pane.layoutPaneID) == true && !part.ids.contains { part.pane.tab($0)?.kind == .browser }))
            && !part.ids.contains { decides(part.pane, $0) } }
        // Keys typed during the read are the close's, never the closing terminal's; a question parks them for its answer.
        // Opened while the closing tab still has the focus; with the hide, every key of the window is the close's.
        let coordinator = services.keyRouter.creationInputCoordinator, keys = coordinator.beginClose(of: tabs, in: window, hides: hides)
        // Rolled back, an emptied pane comes back with its focus (any tab back shows a pane a later close hid: #32898); lifted, its hold goes unshown and the close shows its own (same turn).
        let hidden = !hides ? nil : HiddenTabClose.hide(parts.flatMap { part in part.ids.compactMap { part.pane.tab($0)?.surface } }, in: daemon.store,
                                                        panes: zip(parts, emptied).map { part, emptied in
            let pane = part.pane, selected = pane.stripModel.selectedID, focused = pane.isFocusedInWorkspace
            return { @MainActor restored in
                pane.apply(pane.snapshot())
                if emptied, !restored { _ = pane.showPaneClose() }
                if restored, !pane.stripModel.tabs.isEmpty, let workspace = pane.workspace, workspace.layoutModel.withdrawPaneClose(pane.layoutPaneID) {
                    workspace.applyCurrent()
                    if focused { workspace.layoutModel.focus(pane.layoutPaneID, notify: false); PaneHandlers.focus(pane.layoutPaneID, in: workspace) }
                }
                if restored, let selected { pane.applySelection(selected) }
            }
        }, lifted: zip(parts, emptied).filter { $0.1 }.map { part in { @MainActor in _ = part.0.pane.workspace?.layoutModel.withdrawPaneClose(part.0.pane.layoutPaneID) } })
        Task { @MainActor in
            let (prompt, asked) = await promptAndAnswers(closing: tabs, on: daemon, services: services, confirmed: true) // no answer asks
            reading.subtract(ids)
            guard let prompt else {
                asking.subtract(ids)
                close(asked, hidden)
                return coordinator.endClose(keys, in: window)
            }
            // A program runs: its tab comes back in place, selected, before the question.
            hidden?.restore()
            let parked = coordinator.parkClose(keys, in: window)
            DestructiveConfirmation.present(prompt, in: window, settings: services.settings) {
                asking.subtract(ids)
                if $0 { close(asked, nil) }
                coordinator.endClose(nil, parked: parked, stays: !$0, in: window)
            }
        }
    }

    /// The tabs whose close is still asking (the daemon's read, then the question): they
    /// stay in their strip, selected, until it answers; a second close of them is the same close.
    private(set) static var asking: Set<String> = []
    /// Those still in the daemon's read: a quick next Cmd-W skips them. Once the question
    /// shows, a Cmd-W behind it closes nothing until the person answers.
    private(set) static var reading: Set<String> = []

    /// ``TabStripModel/cmdWTarget(_:closing:skipped:)`` for `pane`: its tabs still in the daemon's read, or whose page
    /// decides its close (``PageClosingTabs``), are closing; tabs whose question shows are never the next one.
    static func cmdWTarget(_ id: StripTabID, in pane: PaneController) -> StripTabID? {
        let pages = pane.services.closedTabs?.undoToasts.pageClosing
        return pane.stripModel.cmdWTarget(id, closing: { reading.contains($0.rawValue) || pages?.contains($0.rawValue) == true },
                                          skipped: { asking.contains($0.rawValue) })
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
    static func asks(_ tabs: [TabModel], services: AppServices) -> Bool { reads(tabs, services: services) != nil }

    /// The warnings and the closing live terminals' working agents and others (a read asks those); nil: nothing asks.
    private static func reads(_ tabs: [TabModel], services: AppServices) -> (warnTab: Bool, warnAgent: Bool, agents: [String], others: [TabModel])? {
        let snapshot = services.settings?.snapshot
        let warnTab = snapshot?.warnBeforeClosingTab ?? CmuxConfigSnapshot.closeWarningFallback
        let warnAgent = snapshot?.warnBeforeClosingAgentSession ?? CmuxConfigSnapshot.closeWarningFallback
        let terminals = tabs.filter { $0.kind == .pty && !$0.dead }
        guard warnTab || warnAgent, !terminals.isEmpty else { return nil }
        // A terminal with a working agent is that agent's question, never the program one.
        return (warnTab, warnAgent, terminals.compactMap(workingAgent), terminals.filter { workingAgent($0) == nil })
    }

    private static func question(_ tabs: [TabModel], _ reads: (warnTab: Bool, warnAgent: Bool, agents: [String], others: [TabModel]), _ answers: [SurfaceID: ProcessAnswer], confirmed: Bool) -> DestructiveConfirmation.Prompt? {
        let unanswered = confirmed ? reads.others.filter { answers[$0.surface] == .noAnswer }.map(\.displayTitle) : [] // named apart: a title is no program
        return CloseWarning.of(agents: reads.agents, programs: answers.programNames, unanswered: unanswered, warnTab: reads.warnTab, warnAgent: reads.warnAgent).map { prompt($0, closing: tabs) }
    }

    /// The question for closing `tabs` (a tab, a selection, a tab group), or nil to close at once (only a working
    /// agent or a foreground program asks), plus each terminal it asked and its answer.
    /// `confirmed`: a terminal that gives no answer asks, and counts as running its title: only a confirmed "no program"
    /// closes it without the question (lead, #31875).
    static func promptAndAnswers(closing tabs: [TabModel], on daemon: DaemonService, services: AppServices,
                                 confirmed: Bool = false) async -> (prompt: DestructiveConfirmation.Prompt?, asked: RunningPrograms) {
        guard let reads = reads(tabs, services: services) else { return (nil, [:]) }
        let answers = reads.warnTab ? await daemon.processAnswers(of: reads.others) : [:]
        return (question(tabs, reads, answers, confirmed: confirmed), RunningPrograms(answers, of: reads.others, unansweredRunsTitle: confirmed))
    }

    static func prompt(_ warning: CloseWarning, closing tabs: [TabModel]) -> DestructiveConfirmation.Prompt {
        let title = tabs.count == 1 ? ConfirmationStrings.closeTitle(tabs[0].title) : ConfirmationStrings.closeTabsTitle(tabs.count)
        switch warning {
        case .agent(let agent):
            return .init(title: title, body: ConfirmationStrings.agentStillWorking(agent),
                         button: ConfirmationStrings.close, suppresses: CmuxConfigSnapshot.warnBeforeClosingAgentSessionPath)
        case .programs(let programs, let unanswered):
            let body = [programs.isEmpty ? nil : ConfirmationStrings.stillRunning(programs.joined(separator: ", ")),
                        unanswered.isEmpty ? nil : ConfirmationStrings.noAnswer(unanswered.joined(separator: ", "))].compactMap { $0 }
            return .init(title: title, body: body.joined(separator: " "), button: ConfirmationStrings.close, suppresses: CmuxConfigSnapshot.warnBeforeClosingTabPath)
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
