#if DEBUG || CMUX_BENCH_HOOKS
import AppKit
import CmuxNextBridge
import CmuxNextAppCore
import CmuxNextDaemon
import CmuxNextWorkspaceNaming
import CmuxNextSettings

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

        // Home is native: it settles on its own conditions, and neither the
        // agent pane's readiness nor its web view is part of its picture.
        let isHome = definition.name == Self.homeChiefScene || definition.name == Self.homeChiefLongDraftScene
        let readiness = await DebugAgentPane.handle(["action": .string("readiness")], services)
        guard isHome || readinessIsComplete(readiness) else {
            return .object([
                "error": .string("agent pane is blank or composer is hidden"),
                "scene": .string(definition.name), "readiness": readiness, "turn": turn,
            ])
        }

        let sceneAction = await applySceneAction(definition.name)
        let actionReadiness = isHome
            ? await showHomeChief(windowID: targetWindowID, longDraft: definition.name == Self.homeChiefLongDraftScene) : await waitForSceneAnimation()
        guard case .object(let actionReadinessReport) = actionReadiness,
              actionReadinessReport["error"] == nil,
              isHome || actionReadinessReport["animations_pending"]?.boolValue == false else {
            return .object(["error": .string(isHome ? "Home scene did not settle" : "scene popover did not become opaque before capture"),
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
        guard isHome || (result["webviews_composited"]?.intValue ?? 0) > 0 else {
            return .object([
                "error": .string("agent web view was not composited"),
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

    /// The agent pane drew the worked turn and shows its composer.
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
        CaptureSceneDefinition(name: "hints-cmd-held", description: "Command modifier hint destination."),
        CaptureSceneDefinition(name: "hints-ctrl-held", description: "Control modifier hint destination."),
        CaptureSceneDefinition(name: "workspace-auto-name",
                               description: "A real agent chat changes a daemon-owned workspace from its first auto name to its generated title."),
        CaptureSceneDefinition(name: homeChiefScene,
                               description: "Home's empty Chief conversation listing the showcase agents and terminal agents waiting, failed, done and working; click_agent N clicks row N (from 0) and reports the focused tab, click_path snapshots after it."),
        // A literal name: cmux-ci capture finds scenes by `CaptureSceneDefinition(name: "…")`.
        CaptureSceneDefinition(name: "home-chief-long-draft",
                               description: "The home-chief scene with a long draft that grows the field up into the first-run panel; the panel drops what does not fit and nothing it shows runs under the field."),
    ]
}

/// A real daemon workspace and agent tab for before/after auto-name captures.
extension CaptureSceneRegistry {
    static let workspaceAutoNameScene = "workspace-auto-name"
    private static let autoNameSession = "mock-session"
    private static let firstAutoName = "First chat title"
    private static let generatedAutoName = "Updated chat title"

    func renderWorkspaceAutoName(_ params: [String: CmuxNextSettings.JSONValue], definition: CaptureSceneDefinition,
                                 windowID: String) async -> CmuxNextSettings.JSONValue {
        guard let connection = services.daemon.connection,
              let controller = services.windows.controller(for: windowID) else {
            return .object(["error": .string("auto-name scene has no daemon or window"), "scene": .string(definition.name)])
        }
        do {
            let workspaceID = try await services.windows.createWorkspace(WorkspaceSpawn(newTabPage: true),
                                                                            on: services.daemon)
            let key = WorkspaceKey(rawValue: workspaceID)
            services.windows.claimNew(workspaceID: workspaceID, window: windowID)
            guard let pane = await services.daemon.store.firstPane(mirroring: key),
                  let workspace = services.daemon.store.workspace(key: key) else {
                return .object(["error": .string("auto-name workspace has no mirrored pane"), "scene": .string(definition.name)])
            }
            guard workspace.nameSource == .auto else {
                return .object(["error": .string("auto-name workspace source is \(workspace.nameSource.rawValue), expected auto"),
                                "scene": .string(definition.name)])
            }
            _ = try await connection.renameWorkspace(key, to: Self.firstAutoName, source: .auto,
                                                      expectedNameRevision: workspace.nameRevision)
            let seeded = await autoNameSettled { workspace.name == Self.firstAutoName && workspace.nameSource == .auto }
            guard seeded.0 != nil else {
                return .object(["error": .string("first automatic name did not mirror"), "scene": .string(definition.name)])
            }
            let firstRevision = workspace.nameRevision
            let pending = try services.agentTabs.open(in: pane.handle, of: services.daemon, session: Self.autoNameSession, linked: true)
            let created = try await pending.value()
            controller.state.selection.select(created.key, in: pane.id)
            _ = services.revealTab(created.key, intent: .focus)
            controller.sidebar.restore(width: 300, hidden: false)
            guard let session = workspace.screens.flatMap(\.panes).flatMap(\.tabs).first(where: { $0.id == created.key })?.agentSession else {
                return .object(["error": .string("auto-name fixture tab has no mirrored agent session"), "scene": .string(definition.name)])
            }
            let turns = AgentTurnStateStore.shared
            if session.host != turns.localHost, !turns.mirroredHosts.contains(session.host) {
                turns.mirroredHosts.insert(session.host)
            }
            // The fixture supplies an acpmux summary. Only the production namer may write its title.
            let summary: [String: Any] = ["sessionId": Self.autoNameSession, "title": Self.generatedAutoName, "titleSource": "generated"]
            let title = AgentTurnStates.title(summary)
            let generatedTitle = AgentTurnStates.title(summary, includingPrompt: false)
            AgentTurnStateStore.shared.apply(session: Self.autoNameSession, state: nil, lastMessage: nil, muted: false,
                                              title: title, generatedTitle: generatedTitle, detail: nil, recordsTimeline: false,
                                              source: "capture-scene")
            let expected = WorkspaceAutoNameWiring(services: services).reader.rule.persistedName(
                name: Self.firstAutoName, title: nil, front: .chat(userName: nil, title: title, generatedTitle: generatedTitle),
                isLocalMachine: true, supportsNameSource: true, alreadyRenamed: false,
                nameSource: .auto, nameRevision: firstRevision, allowsLegacyDefaults: false) ?? Self.firstAutoName
            let (settled, frameStats) = await autoNameSettled {
                self.autoNameReady(workspace: workspace, tabID: created.key, windowID: windowID, expected: expected)
            }
            var report: [String: CmuxNextSettings.JSONValue] = [
                "scene": .string(definition.name), "description": .string(definition.description),
                "workspace": .string(workspace.id), "tab": .string(created.key),
                "first_name": .string(Self.firstAutoName), "first_name_revision": .number(Double(firstRevision)),
                "workspace_name": .string(workspace.name), "workspace_name_source": .string(workspace.nameSource.rawValue),
                "workspace_name_revision": .number(Double(workspace.nameRevision)),
                "generated_title": generatedTitle.map(CmuxNextSettings.JSONValue.string) ?? .null,
                "expected_name": .string(expected), "frames": frameStats,
            ]
            guard let settled else {
                let readiness = autoNameReadinessSummary(workspace: workspace, tabID: created.key, windowID: windowID, expected: expected).summary
                report["error"] = .string("auto-name scene did not settle: \(readiness)")
                return .object(report)
            }
            var snapshotParams = params
            snapshotParams["window"] = .string(windowID)
            let snapshot = await DebugWindowSnapshot.captureAsync(snapshotParams, services: services)
            guard case .object(var result) = snapshot else { return snapshot }
            for (key, value) in report { result[key] = value }
            result["settled_ms"] = .number(settled)
            guard (result["webviews_composited"]?.intValue ?? 0) > 0 else {
                result["error"] = .string("auto-name agent web view was not composited")
                return .object(result)
            }
            return .object(result)
        } catch {
            return .object(["error": .string("auto-name scene failed: \(error)"), "scene": .string(definition.name)])
        }
    }

    /// A frame-based condition wait: no sleeps or socket polling.
    private func autoNameSettled(_ ready: @escaping () -> Bool) async -> (Double?, CmuxNextSettings.JSONValue) {
        frames.start()
        let settled = await frames.settled(until: ready, start: ContinuousClock.now, window: 100, deadline: 10_000)
        return (settled, frames.stop())
    }

    private func autoNameReady(workspace: WorkspaceModel, tabID: String, windowID: String, expected: String) -> Bool {
        autoNameReadinessSummary(workspace: workspace, tabID: tabID, windowID: windowID, expected: expected).ready
    }

    private func autoNameReadinessSummary(workspace: WorkspaceModel, tabID: String, windowID: String, expected: String) -> (ready: Bool, summary: String) {
        let nameMatches = workspace.name == expected
        let sourceAuto = workspace.nameSource == .auto
        let tab = workspace.screens.flatMap(\.panes).flatMap(\.tabs).first(where: { $0.id == tabID })
        let sessionMatches = tab?.agentSession?.session == Self.autoNameSession
        let generatedMatches = tab?.agentSession.map { AgentTurnStateStore.shared.generatedTitle(for: $0) == Self.generatedAutoName } ?? false
        let view = services.agentTabs.existingView(tabID)
        let painted = view?.model.hasPainted == true
        let inWindow = view?.webView.window != nil
        let loading = view?.webView.isLoading == true
        let row = services.windows.controller(for: windowID)?.sidebar.model.sections.flatMap(\.workspaces).first { $0.id.rawValue == workspace.id }
        let rowReady = row?.title == expected
        let pending = row?.rowState.isPending == true
        let ready = nameMatches && sourceAuto && tab != nil && sessionMatches && generatedMatches && painted && inWindow && !loading && rowReady && !pending
        let summary = "name=\(workspace.name) expected=\(expected) source=\(workspace.nameSource.rawValue) tab=\(tab != nil) session=\(sessionMatches) generated=\(generatedMatches) painted=\(painted) inWindow=\(inWindow) loading=\(loading) row=\(rowReady) pending=\(pending)"
        return (ready, summary)
    }
}
#endif
