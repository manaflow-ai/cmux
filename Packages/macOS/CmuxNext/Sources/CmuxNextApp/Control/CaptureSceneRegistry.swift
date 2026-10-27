#if DEBUG || CMUX_BENCH_HOOKS
import AppKit
import CmuxNextBridge
import CmuxNextEnergy
import CmuxNextHibernation
import CmuxNextResources
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
    func list() -> JSONValue {
        .array(Self.definitions.map { definition in
            .object(["name": .string(definition.name), "description": .string(definition.description)])
        })
    }

    /// Seeds one dense real scene, waits for the agent page to paint, and snapshots the app window.
    func render(_ params: [String: JSONValue]) async -> JSONValue {
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
        let isNative = isHome || isTaskManager
        let readiness = await DebugAgentPane.handle(["action": .string("readiness")], services)
        guard isNative || readinessIsComplete(readiness) else {
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
        } else {
            actionReadiness = await waitForSceneAnimation()
        }
        guard case .object(let actionReadinessReport) = actionReadiness,
              actionReadinessReport["error"] == nil,
              isNative || actionReadinessReport["animations_pending"]?.boolValue == false else {
            let failure = isHome ? "Home scene did not settle"
                : isTaskManager ? "Task Manager scene did not settle" : "scene popover did not become opaque before capture"
            return .object(["error": .string(failure),
                            "scene": .string(definition.name), "readiness": actionReadiness,
                            "scene_action": sceneAction])
        }
        var snapshotParams = params
        snapshotParams["window"] = .string(targetWindowID)
        let snapshot = await DebugWindowSnapshot.captureAsync(snapshotParams, services: services)
        let click = isHome ? await clickHomeAgent(params, windowID: targetWindowID) : nil
        if isHome { clearShowcaseAgent(windowID: targetWindowID) }
        guard case .object(var result) = snapshot else { return snapshot }
        result["click"] = click
        guard isNative || (result["webviews_composited"]?.intValue ?? 0) > 0 else {
            return .object([
                "error": .string("agent web view was not composited"),
                "scene": .string(definition.name), "readiness": readiness, "snapshot": snapshot,
            ])
        }
        result["scene"] = .string(definition.name)
        result["description"] = .string(definition.description)
        result["settled_ms"] = settled.map(JSONValue.number) ?? .null
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

    private func applySceneAction(_ name: String) async -> JSONValue {
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
        switch name {
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

    /// `energy-saver` (p14-energy-026): Low Power Mode laid over the Mac's inputs through the app's one
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

    static let highEnergyTabScene = "high-energy-tab"

    /// `high-energy-tab` (p14-energy-125): a browser tab opens in the focused pane as a person opens one and hides behind
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

    /// The agent pane drew the worked turn and shows its composer.
    private func readinessIsComplete(_ readiness: JSONValue) -> Bool {
        guard case .object(let report) = readiness else { return false }
        return (report["body_text_length"]?.intValue ?? 0) > 0 && (report["transcript_rows"]?.intValue ?? 0) > 0
            && report["composer_visible"]?.boolValue == true
    }

    private func waitForSceneAnimation() async -> JSONValue {
        await DebugAgentPane.handle(["action": .string("readiness"), "wait_animations": .bool(true)], services)
    }

    private static let definitions: [CaptureSceneDefinition] = [
        CaptureSceneDefinition(name: "main-showcase", description: "Main window with the real showcase fixture."),
        CaptureSceneDefinition(name: "composer", description: "Agent composer fixture with the real context controls."),
        CaptureSceneDefinition(name: "sidebar-tiles", description: "Showcase rail and workspace tiles."),
        CaptureSceneDefinition(name: "settings", description: "Showcase window with the settings destination available."),
        CaptureSceneDefinition(name: "history-narrow", description: "Narrow history destination fixture."),
        CaptureSceneDefinition(name: "hints-cmd-held", description: "Command modifier hint destination."),
        CaptureSceneDefinition(name: "hints-ctrl-held", description: "Control modifier hint destination."),
        CaptureSceneDefinition(name: homeChiefScene,
                               description: "Home's empty Chief conversation listing the showcase agents and terminal agents waiting, failed, done and working; click_agent N clicks row N (from 0) and reports the focused tab, click_path snapshots after it."),
        // A literal name: cmux-ci capture finds scenes by `CaptureSceneDefinition(name: "…")`.
        CaptureSceneDefinition(name: "home-chief-long-draft",
                               description: "The home-chief scene with a long draft that grows the field up into the first-run panel; the panel drops what does not fit and nothing it shows runs under the field."),
        // A literal name: cmux-ci capture finds scenes by `CaptureSceneDefinition(name: "…")`.
        CaptureSceneDefinition(name: "energy-saver",
                               description: "Energy Saver on through simulated Low Power Mode (feature energySaver): the sidebar footer's leaf and its card with the reason and Turn Off for Now."),
        // A literal name: cmux-ci capture finds scenes by `CaptureSceneDefinition(name: "…")`.
        CaptureSceneDefinition(name: "high-energy-tab",
                               description: "A hidden browser tab whose renderer used 8 percent of one core over the last minute (feature highEnergyTabs, fixture readings): its hover card says Using high energy, with Discard."),
        CaptureSceneDefinition(name: "task-manager",
                               description: "The Task Manager with taskManagerMemorySaved on: the app's processes, then two pages Memory Saver discarded (one saved about 182 MB, one with no measurement) and the Memory Saver freed footer."),
    ]
}
#endif
