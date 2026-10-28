#if DEBUG || CMUX_BENCH_HOOKS
import AppKit
import CmuxHomeCore
import CmuxNextActions
import CmuxNextDaemon
import CmuxNextHome
import CmuxNextSettings

/// One agent `home-chief` adds to the Your agents list beside the waiting
/// one, in its own terminal: what the list should call it and its name.
nonisolated enum HomeSceneAgent: CaseIterable {
    /// A hook reports idle and a program in the terminal reports OSC 9;4
    /// error progress, then keeps running: the next prompt would clear it.
    case failed
    /// A hook reports a finished turn.
    case done
    /// A hook reports work in progress.
    case working

    /// The tab's name (a user rename), so each row says which one it is.
    var name: String {
        switch self {
        case .failed: "deploy"
        case .done: "tests"
        case .working: "build"
        }
    }

    var status: HomeAgentGlance.Status {
        switch self {
        case .failed: .failed
        case .done: .done
        case .working: .working
        }
    }

    /// The tab shows this agent's state in the app's mirror.
    @MainActor func reached(_ tab: TabModel) -> Bool {
        switch self {
        case .failed: tab.agent != nil && tab.progress?.state == .error
        case .done: tab.agent?.state == .done
        case .working: tab.agent?.state == .working
        }
    }
}

extension CaptureSceneRegistry {
    /// The capture window's live terminals: the focused pane's first, then
    /// every pane's in layout order.
    func liveTerminals(_ controller: WindowController) -> [(pane: PaneController, tab: TabModel)] {
        let panes = [controller.focusedPane].compactMap { $0 }
            + (controller.content?.panes.values.sorted { $0.paneKey < $1.paneKey } ?? [])
        var seen: Set<String> = []
        return panes.flatMap { pane in pane.pane.tabs.filter { $0.kind == .pty && !$0.dead }.map { (pane, $0) } }
            .filter { seen.insert($0.tab.id).inserted }
    }

    /// Opens a terminal in `pane` the way the sidebar's New Terminal Tab
    /// does and waits for its record; the scene closes it after its snapshot.
    func openSceneTerminal(_ controller: WindowController, in pane: PaneController) async -> (pane: PaneController, tab: TabModel)? {
        let before = Set(liveTerminals(controller).map(\.tab.id))
        _ = services.registry.perform("newSurface", invocation: ActionInvocation(target: ActionTargetRef(kind: .pane, id: pane.pane.id)))
        frames.start()
        _ = await frames.settled(until: { [self] in liveTerminals(controller).contains { !before.contains($0.tab.id) } },
                                 start: ContinuousClock.now, window: 0, deadline: 5_000)
        _ = frames.stop()
        guard let opened = liveTerminals(controller).first(where: { !before.contains($0.tab.id) }) else { return nil }
        openedTerminals.append(opened.tab.id)
        return opened
    }

    /// Opens one terminal per `HomeSceneAgent` and reports each through the
    /// production paths: a user rename, a hook's `report-agent`, and for the
    /// failed one OSC 9;4 error progress from a program left running (a
    /// shell prompt clears progress), which the daemon parses as any
    /// program's. Waits until the mirror shows each state; returns the
    /// agents' tabs, or an error naming the one missing.
    func reportSceneAgents(_ controller: WindowController,
                           in pane: PaneController) async -> Result<[(HomeSceneAgent, TabModel)], SceneAgentError> {
        var opened: [(HomeSceneAgent, PaneController, TabModel)] = []
        for agent in HomeSceneAgent.allCases {
            guard let terminal = await openSceneTerminal(controller, in: pane) else { return .failure(SceneAgentError("no terminal opened for \(agent)")) }
            opened.append((agent, terminal.pane, terminal.tab))
        }
        for (agent, pane, tab) in opened {
            let surface = tab.surface, name = agent.name
            pane.daemon.send("showcase agent name") { connection in try await connection.renameTab(surface, to: name) }
            reportShowcaseAgent(agent == .failed ? .idle : agent == .done ? .done : .working, on: (pane, tab))
        }
        guard let entry = opened.first(where: { $0.0 == .failed }) else { return .failure(SceneAgentError("no failed agent")) }
        let failedPane = entry.1, failed = entry.2
        // The shell may not read input yet (it can flush typeahead at start):
        // print again until the daemon reports the error progress.
        let surface = failed.surface
        for _ in 0..<4 where failed.progress?.state != .error {
            failedPane.daemon.send("showcase agent failed") { connection in
                _ = try await connection.request(SendInputRequest(surface: surface, text: "printf '\\033]9;4;2;100\\007'; sleep 86400\r"))
            }
            frames.start()
            _ = await frames.settled(until: { failed.progress?.state == .error }, start: ContinuousClock.now, window: 0, deadline: 2_000)
            _ = frames.stop()
        }
        frames.start()
        _ = await frames.settled(until: { opened.allSatisfy { $0.0.reached($0.2) } }, start: ContinuousClock.now, window: 0, deadline: 5_000)
        _ = frames.stop()
        if let missing = opened.first(where: { !$0.0.reached($0.2) }) {
            return .failure(SceneAgentError("\(missing.0) agent's state did not reach the mirror"))
        }
        return .success(opened.map { ($0.0, $0.2) })
    }

    /// After the snapshot, with `click_agent` N: clicks Your agents row N,
    /// counted from 0 (a pointer click through the window; VoiceOver's press
    /// if that opens nothing) and reports the window's focused tab against the row's,
    /// with a second snapshot at `click_path`. Nil without `click_agent`.
    func clickHomeAgent(_ params: [String: CmuxNextSettings.JSONValue], windowID: String) async -> CmuxNextSettings.JSONValue? {
        guard let index = params["click_agent"]?.intValue else { return nil }
        guard let controller = services.windows.controller(for: windowID),
              let page = controller.topPages.views[.home] as? TopHomePageView,
              let chief = TopHomePageView.chief(services.home) else {
            return .object(["error": .string("Home is not shown")])
        }
        // A click on a window that is not key makes it key first: make it key
        // as it is under a user's pointer.
        let wasKey = controller.window?.isKeyWindow ?? false
        if !wasKey {
            // Activation is asynchronous and can be refused (a capture slot's
            // app in the background): wait briefly, and report what it got.
            NSApp.activate()
            controller.window?.makeKeyAndOrderFront(nil)
            frames.start()
            _ = await frames.settled(until: { controller.window?.isKeyWindow == true },
                                     start: ContinuousClock.now, window: 0, deadline: 1_000)
            _ = frames.stop()
        }
        // The window can leave Home after the snapshot (a capture once showed
        // the newest terminal's workspace by the click): show it again first.
        let wasShown = page.host.flatMap(HomePageTab.transcript(in:))?.debugFirstRunShown == true
        if !wasShown {
            TopPages.show(.home, services: services, in: controller.state)
            page.show(ConversationID(chief))
            frames.start()
            _ = await frames.settled(until: { page.host.flatMap(HomePageTab.transcript(in:))?.debugFirstRunShown == true },
                                     start: ContinuousClock.now, window: 100, deadline: 3_000)
            _ = frames.stop()
        }
        guard let transcript = page.host.flatMap(HomePageTab.transcript(in:)), transcript.debugFirstRunShown else {
            return .object(["error": .string("Home's first-run panel is not shown"), "home_reshown": .bool(!wasShown)])
        }
        let rows = transcript.debugFirstRunAgents
        var report: [String: CmuxNextSettings.JSONValue] = ["index": .number(Double(index)), "window_was_key": .bool(wasKey),
                                                            "window_key": .bool(controller.window?.isKeyWindow ?? false)]
        report["home_reshown"] = .bool(!wasShown)
        report["rows"] = .array(rows.map { row in
            .object(["tab": .string(row.id), "title": .string(row.title), "status": .string("\(row.status)"), "shown": .bool(row.shown)])
        })
        report["focused_tab_before"] = focusedTab(controller).map(CmuxNextSettings.JSONValue.string) ?? .null
        let pointer = transcript.debugClickFirstRunAgent(index, pointer: true)
        let reached = await focusReaches(pointer, controller)
        report["pointer_clicked_tab"] = pointer.map(CmuxNextSettings.JSONValue.string) ?? .null
        report["pointer_focused_tab"] = focusedTab(controller).map(CmuxNextSettings.JSONValue.string) ?? .null
        var clicked = pointer
        if !reached {
            // The press needs the row on screen: a pointer click that left Home makes it nil.
            let press = transcript.debugClickFirstRunAgent(index, pointer: false)
            _ = await focusReaches(press, controller)
            report["press_clicked_tab"] = press.map(CmuxNextSettings.JSONValue.string) ?? .null
            clicked = press ?? pointer
        }
        report["via"] = .string(reached ? "pointer" : "accessibility_press")
        report["clicked_tab"] = clicked.map(CmuxNextSettings.JSONValue.string) ?? .null
        let focused = focusedTab(controller)
        report["focused_tab"] = focused.map(CmuxNextSettings.JSONValue.string) ?? .null
        report["selected_tab_in_focused_pane"] = controller.focusedPane?.stripModel.selectedID.map { .string($0.rawValue) } ?? .null
        report["focused_matches_clicked"] = .bool(clicked != nil && focused == clicked)
        if let path = params["click_path"] {
            var snapshot = params
            snapshot["path"] = path
            snapshot["window"] = .string(windowID)
            report["snapshot"] = await DebugWindowSnapshot.captureAsync(snapshot, services: services)
        }
        return .object(report)
    }

    /// The tab the window's focus resolves to (a terminal, page or chat).
    func focusedTab(_ controller: WindowController) -> String? {
        NotificationCenterService.contentTab(controller.focus.state.resolved)
    }

    /// Waits up to 3 s for the window's focus to reach `tab`.
    private func focusReaches(_ tab: String?, _ controller: WindowController) async -> Bool {
        guard let tab else { return false }
        frames.start()
        let reached = await frames.settled(until: { [self] in focusedTab(controller) == tab },
                                           start: ContinuousClock.now, window: 0, deadline: 3_000)
        _ = frames.stop()
        return reached != nil
    }
}

/// Why `home-chief`'s agents did not reach the list.
nonisolated struct SceneAgentError: Error {
    let message: String
    init(_ message: String) { self.message = message }
}
#endif
