#if DEBUG || CMUX_BENCH_HOOKS
import AppKit
import CmuxHomeCore
import CmuxNextActions
import CmuxNextAgentPane
import CmuxNextDaemon
import CmuxNextFeedClient
import CmuxNextHome
import CmuxNextHomeModel
import CmuxNextPages
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

/// `permission-feed-peer(-resolved)`: the real feed bridge against HomeNeedsYouCapture's acpmux and feed stub, in
/// Chief Home's pinned Needs you; resolved: acpmux reports the prompt answered elsewhere (`withdrawn` says if it went).
extension CaptureSceneRegistry {
    func renderPermissionFeedPeer(_ params: [String: CmuxNextSettings.JSONValue], scene: String, windowID: String) async -> CmuxNextSettings.JSONValue {
        let (services, daemon) = (services, services.machines.local.connection)
        await Self.feedOp(daemon, "feed.withdraw", HomeNeedsYouCapture.withdrawParams)
        guard let controller = services.windows.controller(for: windowID), let chief = TopHomePageView.chief(services.home),
              (try? await services.settings?.set(.bool(true), at: HomeNeedsYouSetting.configPath)) != nil,
              let executable = Bundle.main.executableURL?.resolvingSymlinksInPath(),
              let capture = try? HomeNeedsYouCapture(send: { op, data in Task { await Self.feedOp(daemon, op, data) } }) else {
            return .object(["error": .string("no window, Chief, Needs you setting or socket"), "scene": .string(scene)])
        }
        defer { capture.stop() }
        TopPages.show(.home, services: services, in: controller.state)
        let page = controller.topPages.views[.home] as? TopHomePageView
        page?.show(ConversationID(chief))
        let bridge = AcpmuxPermissionFeedBridge(
            environment: AcpmuxEnvironment(executable: executable, home: URL(fileURLWithPath: "/tmp", isDirectory: true),
                                           socketPath: capture.socket, daemonArguments: [], childEnvironment: [:]),
            owner: { _, body in capture.owner(body) }, isSignedIn: { true }, ownInstall: { "inst_capture_mac" },
            presenceKeys: { throw CancellationError() })
        bridge.start()
        let section = { page?.host.flatMap(HomePageTab.transcript(in:))?.pinnedSection as? FeedNeedsYouSection }
        frames.start()
        let shown = await frames.settled(until: { (section()?.waiting ?? 0) > 0 }, start: .now, window: 100, deadline: 8_000)
        var report: [String: CmuxNextSettings.JSONValue] = ["shown_frames": frames.stop(), "connected": .bool(capture.connected)]
        let row = await (section()?.subviews.first as? PageWebView)?.debugWait(selector: ".feed-needs-row", timeoutMilliseconds: 6_000)
        report["row"] = row ?? .null
        if scene.hasSuffix("-resolved"), shown != nil {
            capture.notifyPending()
            capture.resolve()
            frames.start()
            report["withdrawn"] = .bool(await frames.settled(until: { section() == nil }, start: .now, window: 300, deadline: 5_000) != nil)
            report["resolved_frames"] = frames.stop()
        } else if shown != nil {
            capture.notifyPending()
        }
        report["info_reads"] = .array(capture.infoReads.map { .string($0) })
        guard shown != nil, case .object(let drawn)? = row, drawn["matched"]?.boolValue == true else {
            return .object(report.merging(["error": .string("Needs you never drew the prompt"), "scene": .string(scene)]) { $1 })
        }
        var snapshotParams = params
        snapshotParams["window"] = .string(windowID)
        guard case .object(var result) = await DebugWindowSnapshot.captureAsync(snapshotParams, services: services) else {
            return .object(["error": .string("no snapshot"), "scene": .string(scene)])
        }
        withExtendedLifetime(bridge) {}
        result["scene"] = .string(scene)
        result["scene_action"] = .object(report)
        return .object(result)
    }

    /// One `feed.*` op (params: a JSON object) on the app's local daemon connection.
    nonisolated static func feedOp(_ connection: DaemonConnection?, _ operation: String, _ params: Data) async {
        guard let connection,
              let value = try? JSONDecoder().decode([String: CmuxNextDaemon.JSONValue].self, from: params) else { return }
        _ = try? await ResourceRelayClient(connection: connection).send(operation: operation, params: value, idempotencyKey: "capture-\(UUID().uuidString)")
    }
}
#endif
