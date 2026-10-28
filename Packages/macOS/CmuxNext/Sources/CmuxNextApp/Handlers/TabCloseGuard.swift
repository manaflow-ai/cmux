import AppKit
import CmuxNextActions
import CmuxNextAppCore
import CmuxNextBridge
import CmuxNextFocus
import CmuxNextDaemon
import CmuxNextDesign
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
        /// A command runs in a closing terminal, its program not named yet.
        case running
    }

    /// Runs `close` at once, or after the person confirms the question.
    /// `close` gets what the question asked the terminals, so the close's undo
    /// toast decision does not ask them again (one daemon read per Cmd-W, not two).
    ///
    /// The daemon pushes each terminal's shell state (``PushedShellState``): terminals whose own shell sits idle at its prompt
    /// close in the person's own turn with no read, and a running command asks in that turn, so a quick next
    /// Cmd-W goes to the question and never closes an idle neighbour behind it (Lawrence 2026-10-28, shortcut
    /// spam). Only a terminal whose shell reports no state (no shell integration) is read first.
    static func close(_ tabs: [TabModel], on daemon: DaemonService, services: AppServices, window: NSWindow?,
                      close: @escaping @MainActor (_ asked: RunningPrograms) -> Void) {
        guard CloseUndoToasts.isUserClose, window != nil, asks(tabs, services: services) else { return close([:]) }
        // A second close of tabs this close is already asking about (a double click on a close button, a Cmd-W
        // behind the question) is the same close: it goes to the question.
        // CloseUndoToasts.close leaves out tabs whose close already asks; a close of only those goes to the question.
        guard tabs.contains(where: { !asking.contains($0.id) }) else {
            // The question on screen is this press's answer; the HUD says so (no press is silent).
            return services.registry.refuse(RefusalStrings.closeAlreadyAsking)
        }
        let ids = Set(tabs.map(\.id)), terminals = askedTerminals(closing: tabs, services: services)
        // No terminal to ask (the program warning is off, or only agents work): the close, or the agent's
        // question, in the person's own turn.
        guard !terminals.isEmpty else { return answer(tabs, ids: ids, asked: [:], window: window, services: services, close: close) }
        // Every asked terminal's state is pushed: the close, or the question, in the person's own turn.
        let typed = { [weak window] (uptime: TimeInterval) in services.keyRouter.typed(in: window, after: uptime) }
        if let pushed = PushedShellState.programs(terminals, typedSince: typed) {
            guard pushed.values.contains(where: { $0 != nil }) else {
                return answer(tabs, ids: ids, asked: pushed, window: window, services: services, close: close)
            }
            return askNow(tabs, ids: ids, terminals: terminals, pushed: pushed, on: daemon, window: window, services: services, close: close)
        }
        asking.formUnion(ids)
        reading[ids] = []
        // Only the daemon's read is awaited, off main; the close or the question is the person's completion, one
        // userBlocking task that answers the press.
        let end = services.registry.completion(on: services.mainWork)
        end.start {
            let asked = await DestructiveConfirmation.runningPrograms(bySurface: terminals, on: daemon)
            end.post(owner: "TabCloseGuard.close", answering: true) {
                let pending = reading.removeValue(forKey: ids) ?? []
                answer(tabs, ids: ids, asked: asked, window: window, services: services, close: close)
                runDeferred(pending, questionOpen: tabs.contains { asking.contains($0.id) }, services: services)
            }
        }
    }

    // The presses made while a close read its terminals (a terminal that reports no shell state) are kept per read
    // (``reading``), in order, and run once the read answered: to the question when one shows, else each closes the
    // next tab as the strip is then (Lawrence 2026-10-28: presses during a confirmation go to it, and never close an
    // idle neighbour behind a question that has not shown yet).

    /// Keeps a person's Close Tab press aimed at `tab` while its close reads its terminals; false when no read runs.
    /// `isRepeat`: the press is a key repeat (it keeps the boundary rule when it runs).
    static func defers(_ tab: StripTabID, isRepeat: Bool) -> Bool {
        guard let key = reading.keys.first(where: { $0.contains(tab.rawValue) }) else { return false }
        reading[key, default: []].append(isRepeat)
        return true
    }

    /// Runs the kept presses of a read that answered: into the open question (they close nothing; the HUD says so),
    /// else each as a Close Tab of its own, in order.
    private static func runDeferred(_ presses: [Bool], questionOpen: Bool, services: AppServices) {
        for isRepeat in presses {
            if questionOpen { services.registry.refuse(RefusalStrings.closeAlreadyAsking); continue }
            services.registry.perform("closeTab", invocation: ActionInvocation(arguments: [deferredRepeatArgument: .bool(isRepeat)], origin: .user))
        }
    }

    /// The invocation argument a kept press runs with: whether it was a key repeat.
    static let deferredRepeatArgument = "deferredRepeat"

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

    /// `tab`'s pushed shell state (``PushedShellState``).
    static func pushedState(_ tab: TabModel) -> PushedShellState { PushedShellState(tab) }

    /// A running command asks in the person's own turn (`pushed`); the read names the programs and updates the
    /// question in place. The person's answer closes with the newest names known.
    private static func askNow(_ tabs: [TabModel], ids: Set<String>, terminals: [TabModel], pushed: RunningPrograms, on daemon: DaemonService,
                               window: NSWindow?, services: AppServices, close: @escaping @MainActor (_ asked: RunningPrograms) -> Void) {
        guard let prompt = question(closing: tabs, asked: pushed, services: services) else {
            return close(pushed)
        }
        asking.formUnion(ids)
        let known = NamedPrograms(pushed)
        let dialog = DestructiveConfirmation.present(prompt, in: window, settings: services.settings) {
            asking.subtract(ids)
            known.answered = true
            if $0 { close(known.asked) }
        }
        guard let dialog else { return }
        // Only the names are read, off main; the question is already up.
        let busy = terminals.filter { PushedShellState($0) == .busy }
        let end = services.registry.completion(on: services.mainWork)
        end.start {
            let read = await DestructiveConfirmation.runningPrograms(bySurface: busy, on: daemon)
            end.post(owner: "TabCloseGuard.askNow") {
                // Answered already: nothing to name. A command that ended meanwhile still asked; the read only
                // names what still runs.
                guard !known.answered else { return }
                for (surface, program) in read { if let program { known.asked[surface] = .some(program) } }
                guard let prompt = question(closing: tabs, asked: known.asked, services: services) else { return }
                CmuxDialogCenter.shared.update(dialog, spec: DestructiveConfirmation.spec(prompt))
            }
        }
    }

    /// What the terminals of one open pushed-state question run (``askNow``), named as the read answers.
    private final class NamedPrograms {
        var asked: RunningPrograms
        var answered = false
        init(_ asked: RunningPrograms) { self.asked = asked }
    }

    /// The tabs whose close is still asking (the daemon's read, then the question): they
    /// stay in their strip, selected, until it answers; a second close of them is the same close.
    private(set) static var asking: Set<String> = []
    /// The closes still in the daemon's read, each with the presses kept behind it (a key repeat or not): a quick
    /// next Cmd-W waits until the read answers (``defers(_:isRepeat:)``). Once the question shows, a Cmd-W behind it
    /// closes nothing until the person answers.
    private(set) static var reading: [Set<String>: [Bool]] = [:]
    /// The tabs of the closes still in the daemon's read.
    static var readingTabs: Set<String> { reading.keys.reduce(into: []) { $0.formUnion($1) } }

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
            pages?.contains(tab.rawValue) == true
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
            // A press kept during a terminal read runs later with its repeat flag (``defers(_:isRepeat:)``).
            let isRepeat = invocation[deferredRepeatArgument]?.boolValue == true
            return .init(time: invocation.inputTimestamp ?? ProcessInfo.processInfo.systemUptime, isKey: isRepeat, isRepeat: isRepeat)
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
        return warning(agents: agents, programs: asked.programNames, unnamed: asked.hasUnnamedProgram, warnTab: warnTab, warnAgent: warnAgent)
            .map { prompt($0, closing: tabs) }
    }

    /// The question for these closing terminals, or nil to close at once. `unnamed`: a command runs whose
    /// program is not named yet (pushed state, before the read).
    static func warning(agents: [String], programs: [String], unnamed: Bool = false, warnTab: Bool, warnAgent: Bool) -> Warning? {
        if warnAgent, let agent = agents.first { return .agent(agent) }
        if warnTab, !programs.isEmpty { return .programs(programs) }
        if warnTab, unnamed { return .running }
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
        case .running:
            return .init(title: title, body: ConfirmationStrings.programStillRunning,
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
