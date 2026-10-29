#if DEBUG || CMUX_BENCH_HOOKS
import AppKit
import CmuxNextAgentPane
import CmuxNextAppCore
import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextEnergy
import CmuxNextFocusUI
import CmuxNextHibernation
import CmuxNextInput
import CmuxNextPages
import CmuxNextResources
import CmuxNextWorkspaceNaming
import CmuxNextSettings
import CmuxNextTabs
import CmuxNextWakeups

/// Describes the named DEBUG scenes available to the deterministic capture route.
struct CaptureSceneDefinition: Sendable {
    let name: String
    let description: String
}

/// Applies a real fixture scene and writes a window snapshot after display frames settle.
@MainActor
final class CaptureSceneRegistry {
    let services: AppServices
    let frames = BenchFrames()
    /// The tab `home-chief` reported as waiting, put back to idle after its snapshot.
    var blockedTerminal: String?
    /// The terminals `home-chief` opened, closed after its snapshot.
    var openedTerminals: [String] = []
    /// Puts back the seams `high-energy-tab` replaced (its readings, its clock, the card's pointer) before the next scene.
    var restoreHighEnergyTab: (() -> Void)?

    /// Creates a registry bound to the running app services.
    init(services: AppServices) {
        self.services = services
    }

    /// The stable scene names exposed to capture scripts and CI.
    func list() -> CmuxNextSettings.JSONValue {
        .array(Self.definitions.map { definition in
            .object(["name": .string(definition.name), "description": .string(definition.description)])
        })
    }

    /// Seeds one dense real scene, waits for the agent page to paint, and snapshots the app window.
    func render(_ params: [String: CmuxNextSettings.JSONValue]) async -> CmuxNextSettings.JSONValue {
        let name = params["scene"]?.stringValue ?? "main-showcase"
        guard let definition = Self.definitions.first(where: { $0.name == name }) else {
            return .object([
                "error": .string("unknown scene"),
                "scene": .string(name),
                "available": list(),
            ])
        }
        guard services.environment.showcase else {
            return .object([
                "error": .string("launch with --showcase to enable deterministic scenes"),
                "scene": .string(name),
            ])
        }
        guard let targetWindow = services.windows.active ?? services.windows.controllers.first,
              targetWindow.window != nil else {
            return .object(["error": .string("no app window is ready"), "scene": .string(name)])
        }
        let targetWindowID = targetWindow.state.id
        if definition.name == Self.workspaceAutoNameScene {
            return await renderWorkspaceAutoName(params, definition: definition, windowID: targetWindowID)
        }

        // Every scene starts from the same dense production fixture. Scene-specific controls below
        // then make the named capture visibly different while preserving real app ownership.
        let seed = DebugShowcase.seed(["focus": .bool(true), "dense": .bool(true), "scene": .string(definition.name)], services: services)
        guard case .object(let seedReport) = seed, seedReport["seeded"]?.boolValue == true else {
            return .object(["error": .string("showcase fixture did not seed"), "scene": .string(definition.name)])
        }
        let start = ContinuousClock.now
        frames.start()
        let settled = await frames.settled(
            until: { [self] in
                // Workspace creation and agent-tab insertion are asynchronous production paths.
                // A display frame alone is not evidence that the fixture is visible.
                self.services.showcase.workspaces.count >= 3
                    && self.services.windows.registry.members(of: targetWindowID).count >= 3
                    && self.services.windows.controller(for: targetWindowID)?.sidebar.model.sections.flatMap(\.workspaces).contains { !$0.rowState.isPending } == true
                    && self.services.showcase.agentTabs.values.contains {
                    guard let view = self.services.agentTabs.existingView($0) else { return false }
                    // Shown and painted, in whichever engine shows the chat.
                    return view.window != nil && view.page.hasPainted
                }
            },
            start: start,
            window: 100,
            deadline: 5_000,
        )
        let frameStats = frames.stop()
        guard settled != nil else {
            return .object([
                "error": .string("scene did not settle before deadline"),
                "scene": .string(definition.name),
                "frames": frameStats,
                "workspaces": .number(Double(services.showcase.workspaces.count)),
                "daemon_workspaces": .number(Double(services.daemon.store.workspaces.count)),
                "window_workspaces": .number(Double(services.windows.registry.members(of: targetWindowID).count)),
                "agent_tabs": .number(Double(services.showcase.agentTabs.count)),
            ])
        }

        let turn = await DebugAgentPane.handle(["action": .string("seed_rows"), "fixture": .string("worked-turn")], services)
        guard case .object(let turnReport) = turn,
              (turnReport["rows"]?.intValue ?? 0) > 0 else {
            return .object(["error": .string("worked agent turn did not seed"), "scene": .string(definition.name), "turn": turn])
        }

        // Home is native: it settles on its own conditions, and neither the
        // agent pane's readiness nor its web view is part of its picture.
        let isHome = definition.name == Self.homeChiefScene || definition.name == Self.homeChiefLongDraftScene
        // The Task Manager is native too: its page covers the agent pane.
        let isTaskManager = definition.name == Self.taskManagerScene
        // The Settings tab covers the agent pane: the scene waits for its own page and row.
        let isSettingsEnergy = definition.name == Self.settingsEnergyScene
        let ownsReadiness = isHome || isTaskManager || isSettingsEnergy
        // The latency HUD is a panel over the showcase window: the window settles as usual.
        let isLatencyHUD = definition.name == Self.latencyHUDScene
        let readiness = await DebugAgentPane.handle(["action": .string("readiness")], services)
        guard ownsReadiness || readinessIsComplete(readiness) else {
            return .object([
                "error": .string("agent pane is blank or composer is hidden"),
                "scene": .string(definition.name), "readiness": readiness, "turn": turn,
            ])
        }

        let sceneAction = await applySceneAction(definition.name)
        let actionReadiness: JSONValue
        if isHome {
            actionReadiness = await showHomeChief(windowID: targetWindowID, longDraft: definition.name == Self.homeChiefLongDraftScene)
        } else if isTaskManager {
            actionReadiness = await showTaskManager(windowID: targetWindowID)
        } else if isSettingsEnergy {
            // `showEnergySetting` waited for the page and its row; its error is the scene's.
            actionReadiness = sceneAction
        } else if isLatencyHUD {
            actionReadiness = await showLatencyHUD(windowID: targetWindowID)
        } else {
            actionReadiness = await waitForSceneAnimation()
        }
        guard case .object(let actionReadinessReport) = actionReadiness,
              actionReadinessReport["error"] == nil,
              ownsReadiness || isLatencyHUD || actionReadinessReport["animations_pending"]?.boolValue == false else {
            if isLatencyHUD { services.actionLatencyHUD.hide() }
            let failure = isHome ? "Home scene did not settle"
                : isTaskManager ? "Task Manager scene did not settle"
                : isSettingsEnergy ? "Settings did not show the Energy Saver row"
                : isLatencyHUD ? "latency HUD scene did not settle" : "scene popover did not become opaque before capture"
            return .object(["error": .string(failure),
                            "scene": .string(definition.name), "readiness": actionReadiness,
                            "scene_action": sceneAction])
        }
        var snapshotParams = params
        snapshotParams["window"] = .string(targetWindowID)
        let snapshot = await DebugWindowSnapshot.captureAsync(snapshotParams, services: services)
        let click = isHome ? await clickHomeAgent(params, windowID: targetWindowID) : nil
        if isHome { clearShowcaseAgent(windowID: targetWindowID) }
        if isLatencyHUD { services.actionLatencyHUD.hide() }
        guard case .object(var result) = snapshot else { return snapshot }
        result["click"] = click
        guard ownsReadiness || Self.pageComposited(result) else {
            return .object([
                "error": .string("agent page was not composited"),
                "scene": .string(definition.name), "readiness": readiness, "snapshot": snapshot,
            ])
        }
        result["scene"] = .string(definition.name)
        result["description"] = .string(definition.description)
        result["settled_ms"] = settled.map(CmuxNextSettings.JSONValue.number) ?? .null
        result["frames"] = frameStats
        result["workspaces"] = .number(Double(services.showcase.workspaces.count))
        result["daemon_workspaces"] = .number(Double(services.daemon.store.workspaces.count))
        result["window_workspaces"] = .number(Double(services.windows.registry.members(of: targetWindowID).count))
        result["agent_tabs"] = .number(Double(services.showcase.agentTabs.count))
        result["turn"] = turn
        result["readiness"] = readiness
        result["action_readiness"] = actionReadiness
        result["scene_action"] = sceneAction
        if definition.name == "hints-cmd-held" || definition.name == "hints-ctrl-held" {
            _ = await DebugShortcutHintControl().handle(["modifier": .string("release")], services: services)
        }
        return .object(result)
    }

    private func applySceneAction(_ name: String) async -> CmuxNextSettings.JSONValue {
        // Keep each scene independent when render-scenes.sh reuses one app.
        // The tile scene opts into the real tray look; the other scenes use the
        // ordinary quiet rows so a previous scene cannot leak its appearance.
        _ = DebugTunables.handle(["action": .string("set"), "key": .string("sidebar.sections.look"),
                                   "value": .string(name == "sidebar-tiles" ? "tray" : "quiet")], services: services)
        _ = await DebugAgentPane.handle(["action": .string("close_menus")], services)
        // The energy-saver scene's simulated Low Power Mode ends before any other scene draws.
        if name != Self.energySaverScene, services.energyMonitor.isSimulated { services.energyMonitor.simulate(nil) }
        restoreHighEnergyTab?()
        restoreHighEnergyTab = nil
        // A start-session card a previous scene raised goes (no Cloud is built for it).
        let chat = services.windows.controllers.lazy.compactMap { $0.content?.focusedPane?.currentTabKey }.first
        if let chat { services.cloudIfBuilt?.toolCards.set([], owner: CloudStartSessionAsks.owner, tab: chat) { _, _, _ in } }
        switch name {
        case "cloud-start-session-ask":
            // The card an agent's `cmux cloud start-session` raises in its chat (CloudStartSessionAsks).
            guard let chat else { return .object(["error": .string("no focused chat tab")]) }
            let card = CloudStartSessionAsks.askCard(tab: chat, text: CloudStartSessionStrings.askNew(agent: "claude", machine: "dev"))
            let shown = services.cloud.toolCards.set([card], owner: CloudStartSessionAsks.owner, tab: chat) { _, _, _ in }
            return .object(["card": .bool(shown), "tab": .string(chat)])
        case "composer":
            return await DebugAgentPane.handle(["action": .string("open_menu"), "label": .string("Model")], services)
        case "sidebar-tiles":
            services.windows.active?.sidebar.restore(width: 300, hidden: false)
            return .object(["sidebar": .string("shown"), "width": .number(300)])
        case "settings":
            return await DebugAgentPane.handle(["action": .string("open_menu"), "label": .string("Effort")], services)
        case "history-narrow":
            return await DebugAgentPane.handle(["action": .string("open_changes")], services)
        case "hints-cmd-held":
            let hint = await DebugShortcutHintControl().handle(["modifier": .string("cmd")], services: services)
            let menu = await DebugAgentPane.handle(["action": .string("open_menu"), "label": .string("Mode")], services)
            return .object(["hint": hint, "menu": menu])
        case Self.energySaverScene:
            return await showEnergySaver()
        case Self.settingsEnergyScene:
            return await showEnergySetting()
        case Self.highEnergyTabScene:
            return await showHighEnergyTab()
        case "hints-ctrl-held":
            let hint = await DebugShortcutHintControl().handle(["modifier": .string("ctrl")], services: services)
            let menu = await DebugAgentPane.handle(["action": .string("open_menu"), "label": .string("Model")], services)
            return .object(["hint": hint, "menu": menu])
        default:
            return .object(["scene": .string(name)])
        }
    }

    static let energySaverScene = "energy-saver"

    /// `energy-saver`: Low Power Mode laid over the Mac's inputs through the app's one
    /// energy monitor (`debug.energy.simulate`), so the policy driver turns the saver on as it would on
    /// a real Mac; then the active sidebar's leaf card opens and the scene waits until both show.
    private func showEnergySaver() async -> JSONValue {
        guard services.energy.driver.isEnabled else {
            return .object(["error": .string("feature energySaver is off: launch with CMUX_ENABLE_FEATURES=energySaver")])
        }
        guard let sidebar = services.windows.active?.sidebar.container.sidebarView else {
            return .object(["error": .string("no active window")])
        }
        services.energyMonitor.simulate(EnergySimulation(lowPowerMode: true))
        frames.start()
        // The leaf shows once the policy reaches the sidebar; the card opens over it, as a hover would.
        let leaf = await frames.settled(until: { sidebar.debugEnergyCardState()["shown"] == "true" },
                                        start: .now, window: 0, deadline: 3_000)
        if leaf != nil { _ = sidebar.debugShowEnergyCard() }
        let settled = await frames.settled(
            until: {
                let state = sidebar.debugEnergyCardState()
                return state["opaque"] == "true" && state["card"] == "true"
            },
            start: .now,
            window: 100,
            deadline: 3_000,
        )
        var report = sidebar.debugEnergyCardState().mapValues { JSONValue.string($0) }
        report["energy_frames"] = frames.stop()
        if settled == nil { report["error"] = .string("the Energy Saver leaf or its card did not show before the deadline") }
        return .object(report)
    }

    static let settingsEnergyScene = "settings-energy"

    /// `settings-energy`: Settings opened on General > Energy Saver, with the choices
    /// this Mac offers ("On Battery" only with a battery). Waits until the Settings page has painted
    /// (its paint is held until its reads finish) and its `energy.saver` row is in the page, then for
    /// the frames after it. The report says what the page leaves out; an error names what never showed.
    private func showEnergySetting() async -> JSONValue {
        guard services.energy.driver.isEnabled else {
            return .object(["error": .string("feature energySaver is off: launch with CMUX_ENABLE_FEATURES=energySaver")])
        }
        let key = EnergySaverSetting.path.joined(separator: ".")
        do {
            try services.settingsWindow.show(section: nil, setting: key)
        } catch {
            return .object(["error": .string(String(describing: error))])
        }
        var report: [String: JSONValue] = ["availability": services.settingsAvailability.json]
        let settingsWindow = services.settingsWindow
        frames.start()
        let painted = await frames.settled(until: { settingsWindow.shownPage?.hasPainted == true },
                                           start: .now, window: 0, deadline: 5_000)
        guard painted != nil, let page = settingsWindow.shownPage else {
            report["settings_frames"] = frames.stop()
            report["error"] = .string("the Settings page did not paint before the deadline")
            return .object(report)
        }
        let row: Bool
        do {
            row = try await page.callPageScript(Self.rowShownScript, arguments: ["key": key, "timeout": 3_000]) as? Bool == true
        } catch {
            report["settings_frames"] = frames.stop()
            report["error"] = .string("the Settings page did not answer: \(error)")
            return .object(report)
        }
        report["row_shown"] = .bool(row)
        guard row else {
            report["settings_frames"] = frames.stop()
            report["error"] = .string("the Settings page drew no \(key) row before the deadline")
            return .object(report)
        }
        // The row is in the document: the frames after it put it on screen before the snapshot.
        _ = await frames.settled(until: { true }, start: .now, window: 100, deadline: 1_000)
        report["settings_frames"] = frames.stop()
        return .object(report)
    }

    /// Resolves true once the page has a laid-out row `key` (`data-row-key`, SettingRow.tsx), false
    /// after `timeout` ms: a MutationObserver on the document, so nothing polls.
    private static let rowShownScript = """
        const selector = `[data-row-key="${CSS.escape(key)}"]`;
        const shown = () => { const row = document.querySelector(selector); return row !== null && row.getClientRects().length > 0; };
        if (shown()) return true;
        return await new Promise((resolve) => {
          const observer = new MutationObserver(() => {
            if (!shown()) return;
            observer.disconnect();
            clearTimeout(timer);
            resolve(true);
          });
          const timer = setTimeout(() => { observer.disconnect(); resolve(false); }, timeout);
          observer.observe(document.documentElement, { childList: true, subtree: true, attributes: true });
        });
        """

    static let highEnergyTabScene = "high-energy-tab"

    /// `high-energy-tab`: a browser tab opens in the focused pane as a person opens one and hides behind
    /// the tab the pane showed; fixture renderer readings (``HighEnergySceneReadings``) give it 8 % of a core over a
    /// whole window; then the pointer rests on it until its card shows "Using high energy" with Discard. The fixtures
    /// and the card's pointer stay until the next scene. An error names the step that never happened.
    private func showHighEnergyTab() async -> JSONValue {
        guard let monitor = services.cache.hibernation?.highEnergy else {
            return .object(["error": .string("feature highEnergyTabs is off: launch with CMUX_ENABLE_FEATURES=highEnergyTabs")])
        }
        let cache = services.cache
        // A titled data page: the card names it without the network.
        guard let pane = services.windows.active?.focusedPane, let shown = pane.stripModel.selectedID,
              let url = URL(string: "data:text/html,%3Ctitle%3EVideo%20render%3C/title%3E%3Ch1%3EVideo%20render%3C/h1%3E"),
              pane.newBrowserTab(url: url) else {
            return .object(["error": .string("the active window has no focused pane to open a browser tab in")])
        }
        frames.start()
        _ = await frames.settled(until: { pane.stripModel.selectedID.map { $0 != shown && cache.browsers[$0.rawValue] != nil } ?? false },
                                 start: .now, window: 0, deadline: 5_000)
        let opened = pane.stripModel.selectedID.flatMap { $0 != shown && cache.browsers[$0.rawValue] != nil ? $0 : nil }
        if let opened { pane.select(shown) }
        let hidden = await frames.settled(until: { opened.map { cache.lifecycle.phase($0.rawValue) == .mountedHidden } ?? true },
                                          start: .now, window: 100, deadline: 5_000)
        let strip = pane.view.stripView
        guard let tab = opened, hidden != nil, let window = strip.window,
              let center = strip.model.orderedTabs.firstIndex(where: { $0.id == tab }).flatMap({ TabStripDebug.tabCenter(in: strip, at: $0) }) else {
            _ = frames.stop()
            return .object(["error": .string("the scene's browser tab did not open and hide in the strip before the deadline")])
        }
        let restoreReadings = HighEnergySceneReadings(busy: tab.rawValue, share: 0.08).install(on: monitor)
        let coordinator = services.hoverCards
        let pointer = (coordinator.pointerLocation, coordinator.windowNumberAt, coordinator.appIsActive)
        restoreHighEnergyTab = { [weak coordinator] in
            restoreReadings()
            if let coordinator { (coordinator.pointerLocation, coordinator.windowNumberAt, coordinator.appIsActive) = pointer }
        }
        let screen = window.convertPoint(toScreen: strip.convert(center, to: nil))
        coordinator.pointerLocation = { screen }
        coordinator.windowNumberAt = { _ in window.windowNumber }
        coordinator.appIsActive = { true }
        TabStripDebug.pointerMoved(in: strip, to: center)
        let target = TabStripDebug.cardTarget(of: tab)
        let settled = await frames.settled(until: { coordinator.isShowing(target) }, start: .now, window: 300, deadline: 4_000)
        var report: [String: JSONValue] = ["tab": .string(tab.rawValue), "card_text": .string(coordinator.report["card_text"] ?? ""),
                                           "high_energy_frames": frames.stop()]
        if settled == nil { report["error"] = .string("the hidden tab's card did not show before the deadline") }
        return .object(report)
    }

    static let taskManagerScene = "task-manager"

    /// `task-manager`: opens the Task Manager in window `windowID` with `taskManagerMemorySaved` on,
    /// over the app's sample plus ``TaskManagerFixtureSource/captureDiscarded``, then waits until its
    /// page is in the window and lists those pages. An error names what never appeared.
    private func showTaskManager(windowID: String) async -> JSONValue {
        guard let controller = services.windows.controllerBuildingIfWaiting(for: windowID) else {
            return .object(["error": .string("capture window is gone")])
        }
        let taskManager = services.taskManager
        guard taskManager.useCaptureFixture(TaskManagerFixtureSource(base: taskManager.source)) else {
            return .object(["error": .string("a Task Manager page is open already; its model keeps the app's source")])
        }
        guard let page = services.pages.show(.taskManager, in: controller, focus: true) else {
            return .object(["error": .string("Task Manager page did not open")])
        }
        frames.start()
        let settled = await frames.settled(
            until: {
                // visibility-walk-allow: the capture waits for what AppKit shows before it snapshots the window; a node would mirror it a turn late
                guard page.window != nil, !page.isHiddenOrHasHiddenAncestor, let model = taskManager.model else { return false }
                return model.memorySaved && model.snapshot.discarded == TaskManagerFixtureSource.captureDiscarded
            },
            start: .now,
            window: 100,
            deadline: 5_000,
        )
        let snapshot = taskManager.model?.snapshot
        var report: [String: JSONValue] = [
            "task_manager_frames": frames.stop(),
            "rows": .number(Double(snapshot?.rows.count ?? 0)),
            "discarded": .number(Double(snapshot?.discarded.count ?? 0)),
            "freed_bytes": .number(Double(snapshot?.freedBytes ?? 0)),
        ]
        if settled == nil { report["error"] = .string("Task Manager did not list the discarded pages before the deadline") }
        return .object(report)
    }

    static let latencyHUDScene = "latency-hud"

    /// `latency-hud`: publishes ``ActionLatencyHUD/captureInputs`` to the app's input latency feed, shows the action latency
    /// HUD over window `windowID` and waits until its input section lists them. The capture's floating windows
    /// include the panel. An error names what never appeared.
    private func showLatencyHUD(windowID: String) async -> JSONValue {
        guard let window = services.windows.controller(for: windowID)?.window else {
            return .object(["error": .string("capture window is gone")])
        }
        let fixture = ActionLatencyHUD.captureInputs
        for slot in fixture { services.inputLatencyFeed.publish(slot) }
        let hud = services.actionLatencyHUD
        hud.hide()
        hud.show(over: window)
        frames.start()
        let settled = await frames.settled(
            until: { hud.isShown && hud.inputRows.count >= fixture.count },
            start: .now,
            window: 100,
            deadline: 5_000,
        )
        var report: [String: JSONValue] = [
            "latency_hud_frames": frames.stop(),
            "input_rows": .number(Double(hud.inputRows.count)),
            "action_rows": .number(Double(hud.rows.count)),
        ]
        if settled == nil { report["error"] = .string("the latency HUD did not list the fixture inputs before the deadline") }
        return .object(report)
    }

    /// The agent pane drew the worked turn and shows its composer.
    /// Whether `snapshot` (``DebugWindowSnapshot/captureAsync(_:services:)``) drew a page image:
    /// a WebKit web view or a Chromium page. The agent chat shows on either engine
    /// (`agent.chromium`, on by default, puts it in Chromium when `browser.defaultEngine` is
    /// Chromium; WebKit otherwise or after a Chromium fallback), so counting only WebKit refused
    /// every Chromium agent page. The snapshot does not say which page is the agent's; the
    /// readiness check before it already proved the agent page has a transcript and a composer,
    /// so this only refuses a still in which no page drew at all.
    static func pageComposited(_ snapshot: [String: CmuxNextSettings.JSONValue]) -> Bool {
        (snapshot["webviews_composited"]?.intValue ?? 0) + (snapshot["chromium_pages_composited"]?.intValue ?? 0) > 0
    }

    /// A Chromium agent can have a live, ready DOM while its backing WKWebView still reports loading
    /// an asynchronous resource. WebKit still needs to finish navigation before seed_rows runs;
    /// the readiness probe below then checks body, transcript and composer for either engine.
    static func agentPageCanSettle(attached: Bool, loading: Bool, chromium: Bool) -> Bool {
        attached && (chromium || !loading)
    }

    private func readinessIsComplete(_ readiness: CmuxNextSettings.JSONValue) -> Bool {
        guard case .object(let report) = readiness else { return false }
        return (report["body_text_length"]?.intValue ?? 0) > 0 && (report["transcript_rows"]?.intValue ?? 0) > 0
            && report["composer_visible"]?.boolValue == true
    }

    private func waitForSceneAnimation() async -> CmuxNextSettings.JSONValue {
        await DebugAgentPane.handle(["action": .string("readiness"), "wait_animations": .bool(true)], services)
    }

    private static let definitions: [CaptureSceneDefinition] = [
        CaptureSceneDefinition(name: "main-showcase", description: "Main window with the real showcase fixture."),
        CaptureSceneDefinition(name: "composer", description: "Agent composer fixture with the real context controls."),
        CaptureSceneDefinition(name: "sidebar-tiles", description: "Showcase rail and workspace tiles."),
        CaptureSceneDefinition(name: "settings", description: "Showcase window with the settings destination available."),
        CaptureSceneDefinition(name: "history-narrow", description: "Narrow history destination fixture."),
        CaptureSceneDefinition(name: "cloud-start-session-ask", description: "An agent's cmux cloud start-session ask card in its chat."),
        CaptureSceneDefinition(name: "hints-cmd-held", description: "Command modifier hint destination."),
        CaptureSceneDefinition(name: "hints-ctrl-held", description: "Control modifier hint destination."),
        CaptureSceneDefinition(name: "workspace-auto-name",
                               description: "A real agent chat changes a daemon-owned workspace from its first auto name to its generated title."),
        CaptureSceneDefinition(name: homeChiefScene,
                               description: "Home's empty Chief conversation listing the showcase agents and terminal agents waiting, failed, done and working; click_agent N clicks row N (from 0) and reports the focused tab, click_path snapshots after it."),
        // A literal name: cmux-ci capture finds scenes by `CaptureSceneDefinition(name: "…")`.
        CaptureSceneDefinition(name: "home-chief-long-draft",
                               description: "The home-chief scene with a long draft that grows the field up into the first-run panel; the panel drops what does not fit and nothing it shows runs under the field."),
        // A literal name: cmux-ci capture finds scenes by `CaptureSceneDefinition(name: "…")`.
        CaptureSceneDefinition(name: "energy-saver",
                               description: "Energy Saver on through simulated Low Power Mode (feature energySaver): the sidebar footer's leaf and its card with the reason and Turn Off for Now."),
        CaptureSceneDefinition(name: "settings-energy",
                               description: "Settings > General opened on the Energy Saver row (feature energySaver), with the modes this Mac offers: On Battery only on a Mac with a battery."),
        // A literal name: cmux-ci capture finds scenes by `CaptureSceneDefinition(name: "…")`.
        CaptureSceneDefinition(name: "high-energy-tab",
                               description: "A hidden browser tab whose renderer used 8 percent of one core over the last minute (feature highEnergyTabs, fixture readings): its hover card says Using high energy, with Discard."),
        CaptureSceneDefinition(name: "task-manager",
                               description: "The Task Manager with taskManagerMemorySaved on: the app's processes, then two pages Memory Saver discarded (one saved about 182 MB, one with no measurement) and the Memory Saver freed footer."),
        CaptureSceneDefinition(name: "latency-hud",
                               description: "The action latency HUD over the showcase window, its input section with three fixture inputs: a terminal key under one 120 Hz frame, a page scroll over it (danger color) and a sidebar click with no presented frame."),
    ]
}

/// A real daemon workspace and agent tab for before/after auto-name captures.
extension CaptureSceneRegistry {
    static let workspaceAutoNameScene = "workspace-auto-name"
    private static let autoNameSession = "mock-session"
    private static let firstAutoName = "First chat title"
    private static let generatedAutoName = "Updated chat title"
    private static let userWorkspaceName = "My workspace"
    private static let laterGeneratedName = "Later chat title"

    func renderWorkspaceAutoName(_ params: [String: CmuxNextSettings.JSONValue], definition: CaptureSceneDefinition,
                                 windowID: String) async -> CmuxNextSettings.JSONValue {
        guard let connection = services.daemon.connection,
              let controller = services.windows.controller(for: windowID) else {
            return .object(["error": .string("auto-name scene has no daemon or window"), "scene": .string(definition.name)])
        }
        let rule = WorkspaceAutoNameWiring(services: services).reader.rule
        guard rule.enabled, rule.variant == .persist else {
            return .object(["error": .string("auto-name capture requires enabled persisted naming"), "scene": .string(definition.name)])
        }
        let mode = params["mode"]?.stringValue ?? "default"
        guard mode == "default" || mode == "after_user_rename" else {
            return .object(["error": .string("unknown auto-name capture mode"), "scene": .string(definition.name), "mode": .string(mode)])
        }
        let keep = params["keep"]?.boolValue == true
        let expectedArgument = params["expected_name"]
        let expectedName = expectedArgument?.stringValue
        guard expectedArgument == nil || expectedName == Self.firstAutoName else {
            return .object(["error": .string("expected_name is only supported as First chat title for the before capture"),
                            "scene": .string(definition.name)])
        }
        var createdKey: WorkspaceKey?
        var addedFixtureHost: String?
        var cleaned = false
        func cleanup() async {
            guard let key = createdKey, !cleaned else { return }
            cleaned = true
            try? await WorkspaceClose.close(key, terminals: [], on: connection, reason: .sessionEnd)
            services.windows.pendingClaims.removeValue(forKey: key.rawValue)
            services.windows.quietClaims.remove(key.rawValue)
            services.windows.reconcileMembership()
            if let host = addedFixtureHost {
                AgentTurnStateStore.shared.mirroredHosts.remove(host)
            }
        }
        func failure(_ message: String) async -> CmuxNextSettings.JSONValue {
            await cleanup()
            return .object(["error": .string(message), "scene": .string(definition.name)])
        }
        do {
            let workspaceID = try await services.windows.createWorkspace(WorkspaceSpawn(newTabPage: true), on: services.daemon)
            let key = WorkspaceKey(rawValue: workspaceID)
            createdKey = key
            services.windows.claimNew(workspaceID: key.rawValue, window: windowID)
            guard let pane = await services.daemon.store.firstPane(mirroring: key),
                  let workspace = services.daemon.store.workspace(key: key) else {
                return await failure("auto-name workspace has no mirrored pane")
            }
            guard workspace.nameSource == .auto else {
                return await failure("auto-name workspace was not automatic")
            }
            _ = try await connection.renameWorkspace(key, to: Self.firstAutoName, source: .auto,
                                                      expectedNameRevision: workspace.nameRevision)
            let seeded = await autoNameSettled { workspace.name == Self.firstAutoName && workspace.nameSource == .auto }
            guard seeded.0 != nil else {
                return await failure("first automatic name did not mirror")
            }
            let firstRevision = workspace.nameRevision
            let pending = try services.agentTabs.open(in: pane.handle, of: services.daemon, session: Self.autoNameSession, linked: true)
            let created = try await pending.value()
            controller.state.selection.select(created.key, in: pane.id)
            _ = services.revealTab(created.key, intent: .focus)
            controller.sidebar.restore(width: 300, hidden: false)
            let sessionSettled = await autoNameSettled {
                workspace.screens.flatMap(\.panes).flatMap(\.tabs).first(where: { $0.id == created.key })?.agentSession?.session == Self.autoNameSession
            }
            guard sessionSettled.0 != nil,
                  let tabSession = workspace.screens.flatMap(\.panes).flatMap(\.tabs)
                      .first(where: { $0.id == created.key })?.agentSession,
                  let fixtureSession = tabSession.session,
                  fixtureSession == Self.autoNameSession else {
                return await failure("auto-name agent tab did not resolve its mock session")
            }
            let host = tabSession.host
            let turns = AgentTurnStateStore.shared
            if host != turns.localHost && !turns.mirroredHosts.contains(host) {
                turns.mirroredHosts.insert(host)
                addedFixtureHost = host
            }
            // The fixture supplies an acpmux summary. Only the production namer may write its title.
            let summary: [String: Any] = ["sessionId": fixtureSession, "title": Self.generatedAutoName, "titleSource": "generated"]
            let title = AgentTurnStates.title(summary)
            let generatedTitle = AgentTurnStates.title(summary, includingPrompt: false)
            guard let generatedTitle, generatedTitle == Self.generatedAutoName else {
                return await failure("generated title fixture did not produce the expected literal title")
            }
            AgentTurnStateStore.shared.apply(session: fixtureSession, state: nil, lastMessage: nil, muted: false,
                                              title: title, generatedTitle: generatedTitle, detail: nil, recordsTimeline: false,
                                              source: "capture-scene")
            let expected = expectedName ?? Self.generatedAutoName
            let (settled, frameStats) = await autoNameSettled {
                self.autoNameReady(workspace: workspace, tabID: created.key, windowID: windowID, expected: expected)
            }
            var report: [String: CmuxNextSettings.JSONValue] = [
                "scene": .string(definition.name), "description": .string(definition.description),
                "workspace": .string(workspace.id), "tab": .string(created.key),
                "first_name": .string(Self.firstAutoName), "first_name_revision": .number(Double(firstRevision)),
                "workspace_name": .string(workspace.name), "workspace_name_source": .string(workspace.nameSource.rawValue),
                "workspace_name_revision": .number(Double(workspace.nameRevision)),
                "generated_title": .string(generatedTitle), "expected_name": .string(expected),
                "mode": .string(mode), "kept": .bool(keep), "user_name": .null,
                "later_generated_name": .null, "frames": frameStats,
            ]
            guard let settled else {
                let diagnostic = autoNameReadiness(workspace: workspace, tabID: created.key, windowID: windowID, expected: expected).diagnostic
                await cleanup()
                report["error"] = .string("auto-name scene did not settle: \(diagnostic)")
                return .object(report)
            }
            var finalSettled = settled
            var finalFrameStats = frameStats
            var finalGeneratedTitle = generatedTitle
            var finalExpectedName = expected
            if mode == "after_user_rename" {
                _ = try await connection.renameWorkspace(key, to: Self.userWorkspaceName, source: .user,
                                                          expectedNameRevision: workspace.nameRevision)
                let laterSummary: [String: Any] = ["sessionId": fixtureSession,
                                                    "title": Self.laterGeneratedName, "titleSource": "generated"]
                let laterTitle = AgentTurnStates.title(laterSummary)
                let laterGeneratedTitle = AgentTurnStates.title(laterSummary, includingPrompt: false)
                guard let laterGeneratedTitle, laterGeneratedTitle == Self.laterGeneratedName else {
                    return await failure("later generated title fixture did not produce the expected literal title")
                }
                AgentTurnStateStore.shared.apply(session: fixtureSession, state: nil, lastMessage: nil, muted: false,
                                                  title: laterTitle, generatedTitle: laterGeneratedTitle, detail: nil,
                                                  recordsTimeline: false, source: "capture-scene")
                let (laterSettled, laterFrameStats) = await autoNameSettled {
                    self.autoNameReady(workspace: workspace, tabID: created.key, windowID: windowID, expected: Self.userWorkspaceName,
                                       expectedSource: .user, expectedGeneratedTitle: laterGeneratedTitle)
                }
                guard let laterSettled else {
                    let diagnostic = autoNameReadiness(workspace: workspace, tabID: created.key, windowID: windowID,
                                                       expected: Self.userWorkspaceName, expectedSource: .user,
                                                       expectedGeneratedTitle: laterGeneratedTitle).diagnostic
                    await cleanup()
                    report["error"] = .string("user rename precedence did not settle: \(diagnostic)")
                    return .object(report)
                }
                finalSettled = laterSettled
                finalFrameStats = laterFrameStats
                finalGeneratedTitle = laterGeneratedTitle
                finalExpectedName = Self.userWorkspaceName
                report["user_name"] = .string(Self.userWorkspaceName)
                report["later_generated_name"] = .string(Self.laterGeneratedName)
            }
            report["workspace_name"] = .string(workspace.name)
            report["workspace_name_source"] = .string(workspace.nameSource.rawValue)
            report["workspace_name_revision"] = .number(Double(workspace.nameRevision))
            report["generated_title"] = .string(finalGeneratedTitle)
            report["expected_name"] = .string(finalExpectedName)
            report["frames"] = finalFrameStats
            var snapshotParams = params
            snapshotParams["window"] = .string(windowID)
            let snapshot = await DebugWindowSnapshot.captureAsync(snapshotParams, services: services)
            guard case .object(var result) = snapshot else {
                await cleanup()
                return snapshot
            }
            for (key, value) in report { result[key] = value }
            result["settled_ms"] = .number(finalSettled)
            guard result["error"] == nil else {
                await cleanup()
                return .object(result)
            }
            guard Self.pageComposited(result) else {
                await cleanup()
                result["error"] = .string("auto-name agent web view was not composited")
                return .object(result)
            }
            if !keep { await cleanup() }
            return .object(result)
        } catch {
            return await failure("auto-name scene failed: \(error)")
        }
    }

    /// A frame-based condition wait: no sleeps or socket polling.
    private func autoNameSettled(_ ready: @escaping () -> Bool) async -> (Double?, CmuxNextSettings.JSONValue) {
        frames.start()
        let settled = await frames.settled(until: ready, start: ContinuousClock.now, window: 100, deadline: 10_000)
        return (settled, frames.stop())
    }

    private func autoNameReady(workspace: WorkspaceModel, tabID: String, windowID: String, expected: String,
                               expectedSource: WorkspaceNameSource = .auto,
                               expectedGeneratedTitle: String = CaptureSceneRegistry.generatedAutoName) -> Bool {
        autoNameReadiness(workspace: workspace, tabID: tabID, windowID: windowID, expected: expected,
                          expectedSource: expectedSource, expectedGeneratedTitle: expectedGeneratedTitle).ready
    }

    private func autoNameReadiness(workspace: WorkspaceModel, tabID: String, windowID: String, expected: String,
                                   expectedSource: WorkspaceNameSource = .auto,
                                   expectedGeneratedTitle: String = CaptureSceneRegistry.generatedAutoName) -> (ready: Bool, diagnostic: String) {
        let tab = workspace.screens.flatMap(\.panes).flatMap(\.tabs).first(where: { $0.id == tabID })
        let tabFound = tab != nil
        let session = tab?.agentSession
        let sessionOK = session?.session == Self.autoNameSession
        let turns = AgentTurnStateStore.shared
        let hostKnown = session.map { $0.host == turns.localHost || turns.mirroredHosts.contains($0.host) } ?? false
        let actualGenerated = session.flatMap { turns.generatedTitle(for: $0) }
        let generatedOK = actualGenerated == expectedGeneratedTitle
        let actualGeneratedPreview = actualGenerated.map { String($0.prefix(32)) } ?? "-"
        let view = services.agentTabs.existingView(tabID)
        let painted = view?.model.hasPainted == true
        // Engine-neutral (perf's PageWebView): in a window, and loading until its page painted there.
        let inWindow = view?.window != nil
        let loading = view?.page.hasPainted != true
        let pageReady = Self.agentPageCanSettle(attached: inWindow, loading: loading, chromium: view?.debugShowsChromium == true)
        let sidebarRow = services.windows.controller(for: windowID)?.sidebar.model.sections.flatMap(\.workspaces)
            .first(where: { $0.id.rawValue == workspace.id })
        let sidebarRowMatches = sidebarRow?.title == expected
        let pending = sidebarRow?.rowState.isPending == true
        let ready = workspace.name == expected && workspace.nameSource == expectedSource
            && tabFound && sessionOK && hostKnown && generatedOK && painted && pageReady && sidebarRowMatches && !pending
        let diagnostic = "name=\(workspace.name),source=\(workspace.nameSource.rawValue),expected=\(expected),tabFound=\(tabFound),sessionOK=\(sessionOK),hostKnown=\(hostKnown),generatedOK=\(generatedOK),actualGenerated=\(actualGeneratedPreview),painted=\(painted),inWindow=\(inWindow),loading=\(loading),sidebarRow=\(sidebarRowMatches),pending=\(pending)"
        return (ready, String(diagnostic.prefix(330)))
    }
}
#endif
