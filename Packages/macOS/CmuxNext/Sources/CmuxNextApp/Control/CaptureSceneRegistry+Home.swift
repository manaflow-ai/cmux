#if DEBUG || CMUX_BENCH_HOOKS
import AppKit
import CmuxHomeCore
import CmuxNextActions
import CmuxNextDaemon
import CmuxNextHome
import CmuxNextSettings

/// `home-chief`: Home in the capture window, showing the Chief conversation
/// with no messages (its first-run panel) beside the seeded showcase agents
/// and one terminal agent per status: waiting, failed, done and working.
extension CaptureSceneRegistry {
    static let homeChiefScene = "home-chief"
    /// `home-chief` with a long draft: the field grows up into the first-run panel.
    static let homeChiefLongDraftScene = "home-chief-long-draft"
    /// The long draft: enough lines to take most of the column.
    static let longDraftText = (1...24).map { "Line \($0) of a long message to the Chief" }.joined(separator: "\n")

    /// Shows the Chief on the window's Home page after a hook reports a
    /// showcase terminal (opened if the window has none) as waiting for
    /// input (the real `report-agent` path) and `reportSceneAgents` opens a
    /// failed, a done and a working agent, then waits until the app shows
    /// them all: each state reached the mirror, and the first-run panel shows
    /// a row for each status. An error names what never appeared.
    func showHomeChief(windowID: String, longDraft: Bool = false) async -> CmuxNextSettings.JSONValue {
        guard let controller = services.windows.controller(for: windowID) else {
            return .object(["error": .string("capture window is gone")])
        }
        let home = services.home
        guard let chief = TopHomePageView.chief(home) else {
            return .object(["error": .string("no Chief conversation"), "home_available": .bool(home.isAvailable),
                            "why": .string(home.unavailableMessage)])
        }
        // Aimed at the capture window's pane: the action's default is the active window's.
        guard let pane = controller.focusedPane ?? controller.content?.panes.values.min(by: { $0.paneKey < $1.paneKey }) else {
            return .object(["error": .string("the capture window has no pane")])
        }
        // The showcase pane may hold only its agent chat: open a terminal.
        var waiting = showcaseTerminal(controller)
        if waiting == nil { waiting = await openSceneTerminal(controller, in: pane) }
        guard let terminal = waiting else {
            return .object(["error": .string("no live terminal in the capture window to report as waiting")])
        }
        reportShowcaseAgent(.blocked, on: terminal)
        // The terminal to put back to idle: focus may move before the snapshot.
        blockedTerminal = terminal.tab.id
        let agents: [(HomeSceneAgent, TabModel)]
        switch await reportSceneAgents(controller, in: pane) {
        case .success(let reported): agents = reported
        case .failure(let error):
            clearShowcaseAgent(windowID: windowID)
            return .object(["error": .string(error.message), "chief": .string(chief)])
        }
        TopPages.show(.home, services: services, in: controller.state)
        guard let page = controller.topPages.views[.home] as? TopHomePageView else {
            clearShowcaseAgent(windowID: windowID)
            return .object(["error": .string("Home page did not open"), "chief": .string(chief)])
        }
        page.show(ConversationID(chief))
        // An empty field: an earlier long-draft scene in this app leaves its draft there.
        page.host.flatMap(HomePageTab.transcript(in:))?.debugSetDraft("")
        let statuses: Set<HomeAgentGlance.Status> = Set(agents.map(\.0.status)).union([.needsYou])
        let start = ContinuousClock.now
        frames.start()
        let settled = await frames.settled(
            until: {
                guard terminal.tab.agent?.state == .blocked, agents.allSatisfy({ $0.0.reached($0.1) }),
                      let host = page.host, host.window != nil, !host.isHiddenOrHasHiddenAncestor,
                      let transcript = HomePageTab.transcript(in: host), transcript.debugFirstRunShown else { return false }
                return statuses.isSubset(of: transcript.debugFirstRunAgents.filter(\.shown).map(\.status))
            },
            start: start,
            window: 100,
            deadline: 10_000,
        )
        let frameStats = frames.stop()
        let transcript = page.host.flatMap(HomePageTab.transcript(in:))
        var report: [String: CmuxNextSettings.JSONValue] = ["chief": .string(chief), "home_frames": frameStats]
        report["shown"] = page.shown.map { CmuxNextSettings.JSONValue.string($0.rawValue) } ?? .null
        report["first_run_shown"] = .bool(transcript?.debugFirstRunShown ?? false)
        report["messages"] = .number(Double(home.homeStore.transcript(for: ConversationID(chief)).count))
        report["blocked_terminal"] = .string(terminal.tab.id)
        report["agents"] = .array((transcript?.debugFirstRunAgents ?? []).map { row in
            .object(["tab": .string(row.id), "title": .string(row.title), "status": .string("\(row.status)"), "shown": .bool(row.shown)])
        })
        guard settled != nil else {
            report["error"] = .string("Home's first-run panel did not show every status before the deadline")
            clearShowcaseAgent(windowID: windowID)
            return .object(report)
        }
        if longDraft {
            guard let transcript else {
                report["error"] = .string("no Home transcript to put the long draft in")
                clearShowcaseAgent(windowID: windowID)
                return .object(report)
            }
            return await growField(transcript, report: report, windowID: windowID)
        }
        return .object(report)
    }

    /// `home-chief-long-draft`: puts a long draft in the field, waits until the field has grown
    /// and the first-run panel has given way, and reports how far its lowest shown part sits
    /// above the field (an error when anything it shows runs under the field).
    private func growField(_ transcript: HomeNativeTranscriptView, report: [String: CmuxNextSettings.JSONValue],
                           windowID: String) async -> CmuxNextSettings.JSONValue {
        var report = report
        let before = transcript.debugFieldTop
        transcript.debugSetDraft(Self.longDraftText)
        let start = ContinuousClock.now
        frames.start()
        let settled = await frames.settled(
            until: { transcript.debugFieldTop < before - 200 && (transcript.debugFirstRunFieldGap ?? 0) >= 0 },
            start: start,
            window: 100,
            deadline: 10_000,
        )
        report["draft_frames"] = frames.stop()
        report["field_grew_by"] = .number(Double(before - transcript.debugFieldTop))
        report["first_run_field_gap"] = transcript.debugFirstRunFieldGap.map { .number(Double($0)) } ?? .null
        report["first_run_parts"] = .object(transcript.debugFirstRunParts.mapValues { .bool($0) })
        if settled == nil {
            report["error"] = .string("the field did not grow, or the first-run panel still runs under it")
            clearShowcaseAgent(windowID: windowID)
        }
        return .object(report)
    }

    /// The showcase terminal the scene marks as waiting: the first live
    /// terminal of the focused pane, else of any pane in layout order.
    func showcaseTerminal(_ controller: WindowController) -> (pane: PaneController, tab: TabModel)? {
        liveTerminals(controller).first
    }

    /// Puts the scene back once its snapshot is taken: the waiting terminal
    /// to idle, and the terminals it opened closed (a script's close never
    /// asks), so later scenes in the same app inherit no agents.
    func clearShowcaseAgent(windowID: String) {
        defer { blockedTerminal = nil; openedTerminals = [] }
        guard let controller = services.windows.controller(for: windowID) else { return }
        if let id = blockedTerminal,
           let terminal = liveTerminals(controller).first(where: { $0.tab.id == id }) {
            reportShowcaseAgent(.idle, on: terminal)
        }
        for id in openedTerminals {
            _ = services.registry.perform("closeTab", invocation: ActionInvocation(target: ActionTargetRef(kind: .tab, id: id), origin: .script))
        }
    }

    /// A hook's report for the showcase terminal (`report-agent`); the
    /// scene puts it back to idle after its snapshot, so later scenes in
    /// the same app do not inherit a waiting agent.
    func reportShowcaseAgent(_ state: AgentState, on terminal: (pane: PaneController, tab: TabModel)) {
        let surface = terminal.tab.surface
        terminal.pane.daemon.send("showcase agent \(state.rawValue)") { connection in
            _ = try await connection.request(ReportAgentRequest(surface: surface, state: state))
        }
    }
}
#endif
