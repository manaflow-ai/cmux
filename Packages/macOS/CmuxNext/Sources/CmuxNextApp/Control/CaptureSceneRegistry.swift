#if DEBUG
import AppKit
import CmuxNextSettings

/// Describes the named DEBUG scenes available to the deterministic capture route.
struct CaptureSceneDefinition: Sendable {
    let name: String
    let description: String
}

/// Applies a real fixture scene and writes a window snapshot after display frames settle.
@MainActor
final class CaptureSceneRegistry {
    private let services: AppServices
    private let frames = BenchFrames()

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
                    && self.services.windows.controller(for: targetWindowID)?.sidebar.model.sections.flatMap(\.workspaces).contains { $0.rowState != .placeholder } == true
                    && self.services.showcase.agentTabs.values.contains {
                    guard let view = self.services.agentTabs.existingView($0) else { return false }
                    return view.webView.window != nil && !view.webView.isLoading
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

        let readiness = await DebugAgentPane.handle(["action": .string("readiness")], services)
        guard case .object(let readinessReport) = readiness,
              (readinessReport["body_text_length"]?.intValue ?? 0) > 0,
              (readinessReport["transcript_rows"]?.intValue ?? 0) > 0,
              readinessReport["composer_visible"]?.boolValue == true else {
            return .object([
                "error": .string("agent pane is blank or composer is hidden"),
                "scene": .string(definition.name), "readiness": readiness, "turn": turn,
            ])
        }

        let sceneAction = await applySceneAction(definition.name)
        let actionReadiness = await waitForSceneAnimation()
        guard case .object(let actionReadinessReport) = actionReadiness,
              actionReadinessReport["error"] == nil,
              actionReadinessReport["animations_pending"]?.boolValue == false else {
            return .object(["error": .string("scene popover did not become opaque before capture"),
                            "scene": .string(definition.name), "readiness": actionReadiness,
                            "scene_action": sceneAction])
        }
        var snapshotParams = params
        snapshotParams["window"] = .string(targetWindowID)
        let snapshot = await DebugWindowSnapshot.captureAsync(snapshotParams, services: services)
        guard case .object(var result) = snapshot else { return snapshot }
        guard (result["webviews_composited"]?.intValue ?? 0) > 0 else {
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
        case "hints-ctrl-held":
            let hint = await DebugShortcutHintControl().handle(["modifier": .string("ctrl")], services: services)
            let menu = await DebugAgentPane.handle(["action": .string("open_menu"), "label": .string("Model")], services)
            return .object(["hint": hint, "menu": menu])
        default:
            return .object(["scene": .string(name)])
        }
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
    ]
}
#endif
