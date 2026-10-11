#if DEBUG
import AppKit
import CmuxHomeCore
import CmuxNextActions
import CmuxNextDaemon
import CmuxNextHome
import CmuxNextSettings

/// `home-chief`: Home in the capture window, showing the Chief conversation
/// with no messages (its first-run panel) beside the seeded showcase agents.
extension CaptureSceneRegistry {
    static let homeChiefScene = "home-chief"

    /// Shows the Chief on the window's Home page after a hook reports a
    /// showcase terminal (opened if the window has none) as waiting for
    /// input (the real `report-agent` path), then waits until the app shows
    /// both: the terminal's blocked state reached the mirror, and the
    /// first-run panel is on screen in the window. An error names what never
    /// appeared.
    func showHomeChief(windowID: String) async -> CmuxNextSettings.JSONValue {
        guard let controller = services.windows.controller(for: windowID) else {
            return .object(["error": .string("capture window is gone")])
        }
        let home = services.home
        guard let chief = TopHomePageView.chief(home) else {
            return .object(["error": .string("no Chief conversation"), "home_available": .bool(home.isAvailable),
                            "why": .string(home.unavailableMessage)])
        }
        // The showcase pane may hold only its agent chat: open a terminal the
        // way the sidebar's New Terminal Tab does, and wait for its record.
        if showcaseTerminal(controller) == nil {
            // Aimed at the capture window's pane: the action's default is the active window's.
            let pane = controller.focusedPane ?? controller.content?.panes.values.min { $0.paneKey < $1.paneKey }
            guard let pane else { return .object(["error": .string("the capture window has no pane")]) }
            let target = ActionTargetRef(kind: .pane, id: pane.pane.id)
            _ = services.registry.perform("newSurface", invocation: ActionInvocation(target: target))
            frames.start()
            _ = await frames.settled(until: { [self] in showcaseTerminal(controller) != nil },
                                     start: ContinuousClock.now, window: 0, deadline: 5_000)
            _ = frames.stop()
        }
        guard let terminal = showcaseTerminal(controller) else {
            return .object(["error": .string("no live terminal in the capture window to report as waiting")])
        }
        reportShowcaseAgent(.blocked, on: terminal)
        // The terminal to put back to idle: focus may move before the snapshot.
        blockedTerminal = terminal.tab.id
        TopPages.show(.home, services: services, in: controller.state)
        guard let page = controller.topPages.views[.home] as? TopHomePageView else {
            reportShowcaseAgent(.idle, on: terminal)
            blockedTerminal = nil
            return .object(["error": .string("Home page did not open"), "chief": .string(chief)])
        }
        page.show(ConversationID(chief))
        let start = ContinuousClock.now
        frames.start()
        let settled = await frames.settled(
            until: {
                guard terminal.tab.agent?.state == .blocked,
                      let host = page.host, host.window != nil, !host.isHiddenOrHasHiddenAncestor,
                      let transcript = HomePageTab.transcript(in: host) else { return false }
                return transcript.debugFirstRunShown
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
        guard settled != nil else {
            report["error"] = .string("Home's first-run panel did not show before the deadline")
            reportShowcaseAgent(.idle, on: terminal)
            blockedTerminal = nil
            return .object(report)
        }
        return .object(report)
    }

    /// The showcase terminal the scene marks as waiting: the first live
    /// terminal of the focused pane, else of any pane in layout order.
    func showcaseTerminal(_ controller: WindowController) -> (pane: PaneController, tab: TabModel)? {
        let panes = [controller.focusedPane].compactMap { $0 }
            + (controller.content?.panes.values.sorted { $0.paneKey < $1.paneKey } ?? [])
        for pane in panes {
            if let tab = pane.pane.tabs.first(where: { $0.kind == .pty && !$0.dead }) { return (pane, tab) }
        }
        return nil
    }

    /// Puts the showcase terminal back to idle once the scene's snapshot is taken.
    func clearShowcaseAgent(windowID: String) {
        defer { blockedTerminal = nil }
        guard let id = blockedTerminal, let controller = services.windows.controller(for: windowID),
              let pane = controller.content?.panes.values.first(where: { $0.pane.tabs.contains { $0.id == id } }),
              let tab = pane.pane.tabs.first(where: { $0.id == id }) else { return }
        reportShowcaseAgent(.idle, on: (pane, tab))
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
