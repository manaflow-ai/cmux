#if DEBUG || CMUX_BENCH_HOOKS
import AppKit
import CmuxNextAgentPane
import CmuxNextAppCore
import CmuxNextBridge
import CmuxNextCloud
import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextSidebar
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
        // A cloud-agent-machines or cloud-machine-disconnected picture stays for the capture's
        // stills; any next render ends it.
        endAgentCloudMachines()
        endCloudMachineDisconnected()
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
                    self.services.agentTabs.existingView($0)?.debugCaptureState.ready == true
                }
            },
            start: start,
            window: 100,
            // A cold launch starts Chromium for the agent page; that start may take up to the page's
            // Chromium deadline (8 s) before WebKit takes over and loads. The route's own 30 s
            // deadline still leaves room for seeding, readiness and the snapshot after this.
            deadline: 20_000,
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
                "agent_pages": .array(services.showcase.agentTabs.values.map {
                    .string(services.agentTabs.existingView($0)?.debugCaptureState.diagnostic ?? "no view")
                }),
            ])
        }

        // The sidebar is its picture: the showcase window, then the machines, with no agent turn.
        if definition.name == Self.cloudAgentMachinesScene || definition.name == Self.cloudAgentMachinesLeakedScene {
            return await renderAgentCloudMachines(params, definition: definition, windowID: targetWindowID)
        }
        // The sidebar's machine headers are its picture: the showcase window, then the machines, with no agent turn.
        if definition.name == Self.cloudMachineDisconnectedScene {
            return await renderCloudMachineDisconnected(params, definition: definition, windowID: targetWindowID)
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
        guard isHome || Self.pageComposited(result) else {
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
        let chat = services.windows.controllers.lazy.compactMap { $0.content?.focusedPane?.currentTabKey }.first
        if let chat { services.cloud.toolCards.set([], owner: CloudStartSessionAsks.owner, tab: chat) { _, _, _ in } }
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
        case "hints-ctrl-held":
            let hint = await DebugShortcutHintControl().handle(["modifier": .string("ctrl")], services: services)
            let menu = await DebugAgentPane.handle(["action": .string("open_menu"), "label": .string("Model")], services)
            return .object(["hint": hint, "menu": menu])
        default:
            return .object(["scene": .string(name)])
        }
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
        CaptureSceneDefinition(name: "cloud-agent-machines",
                               description: "A Cloud machine the person opened (its my-project row) and two that agents made, never opened here, each with its image's own workspace-1: the agents' rows show (leaked: true) or none do (false)."),
        CaptureSceneDefinition(name: "cloud-agent-machines-leaked",
                               description: "The same scene as cloud-agent-machines (an older name, kept for capture commands)."),
        CaptureSceneDefinition(name: "hints-cmd-held", description: "Command modifier hint destination."),
        CaptureSceneDefinition(name: "hints-ctrl-held", description: "Control modifier hint destination."),
        CaptureSceneDefinition(name: "workspace-auto-name",
                               description: "A real agent chat changes a daemon-owned workspace from its first auto name to its generated title."),
        CaptureSceneDefinition(name: homeChiefScene,
                               description: "Home's empty Chief conversation listing the showcase agents and terminal agents waiting, failed, done and working; click_agent N clicks row N (from 0) and reports the focused tab, click_path snapshots after it."),
        // A literal name: cmux-ci capture finds scenes by `CaptureSceneDefinition(name: "…")`.
        CaptureSceneDefinition(name: "cloud-machine-disconnected",
                               description: "Two Cloud machine headers: a running machine whose app link dropped, and one whose connect the provider refused."),
        CaptureSceneDefinition(name: "home-chief-long-draft",
                               description: "The home-chief scene with a long draft that grows the field up into the first-run panel; the panel drops what does not fit and nothing it shows runs under the field."),
    ]
}

/// Leo 2026-10-29, on agents' Cloud machines in his sidebar: "why is there all this weird stuff at the
/// bottom of the sidebar". The account's machine list connects every Cloud machine, and each starts
/// with a workspace from its image: this scene adds two such machines, as that list would, beside one the person opened.
extension CaptureSceneRegistry {
    static let cloudAgentMachinesScene = "cloud-agent-machines"
    static let cloudAgentMachinesLeakedScene = "cloud-agent-machines-leaked"
    /// The machine the person opened, then the two agents made.
    static let openedMachineID = "capture-vm-mine"
    static let agentMachineIDs = ["capture-vm-lane-1", "capture-vm-test-2"]
    static var sceneMachineIDs: [String] { [openedMachineID] + agentMachineIDs }

    /// Adds the three machines to the settled showcase window, opens the person's one (its workspace
    /// claimed into the window, as Open Machine does), scrolls the sidebar to them, and snapshots the
    /// window once the opened machine's row is drawn in view and the agents' rows are either all
    /// drawn (the leak, `leaked: true`) or listed nowhere (`false`). Anything else fails, and the
    /// error names what each machine got to. The capture driver takes its stills after this returns,
    /// so a pictured scene keeps its machines until the next render; a failure takes them away.
    func renderAgentCloudMachines(_ params: [String: CmuxNextSettings.JSONValue], definition: CaptureSceneDefinition,
                                  windowID: String) async -> CmuxNextSettings.JSONValue {
        guard let controller = services.windows.controller(for: windowID) else {
            return .object(["error": .string("no window"), "scene": .string(definition.name)])
        }
        controller.sidebar.restore(width: 300, hidden: false)
        endAgentCloudMachines()
        var shown = false
        defer { if !shown { endAgentCloudMachines() } }
        addAgentCloudMachines()
        services.windows.claim(workspaceID: Self.sceneWorkspace(Self.openedMachineID), in: controller.state, select: false)
        let opened = SidebarRowKey.workspace(WorkspaceID(Self.sceneWorkspace(Self.openedMachineID)))
        let agentRows = Self.agentMachineIDs.map { SidebarRowKey.workspace(WorkspaceID(Self.sceneWorkspace($0))) }
        frames.start()
        let listed = await frames.settled(until: { [self] in agentMachineRow(opened, windowID: windowID) != nil },
                                          start: ContinuousClock.now, window: 300, deadline: 10_000)
        _ = frames.stop()
        scrollToAgentMachines(windowID: windowID)
        let pictured = { [self] in
            guard agentMachineRowShown(opened, windowID: windowID) else { return false }
            let drawn = agentRows.filter { agentMachineRowShown($0, windowID: windowID) }.count
            let absent = Self.agentMachineIDs.filter { id in
                agentMachineRow(.workspace(WorkspaceID(Self.sceneWorkspace(id))), windowID: windowID) == nil
                    && services.windows.registry.value.owner(of: Self.sceneWorkspace(id)) == nil
            }.count
            return drawn == agentRows.count || absent == agentRows.count
        }
        frames.start()
        var settled: Double?
        if listed != nil { settled = await frames.settled(until: pictured, start: ContinuousClock.now, window: 300, deadline: 3_000) }
        let frameStats = frames.stop()
        let report = agentMachinesReport(windowID: windowID)
        // Checked again in the snapshot's own turn: the settle window must not have moved it.
        guard settled != nil, pictured() else {
            return .object(["error": .string("\(definition.name): \(listed == nil ? "the opened machine's row never listed" : "rows never settled in view") [\(Self.summary(report))]"),
                            "scene": .string(definition.name), "scene_action": report, "frames": frameStats])
        }
        let leaked = agentRows.allSatisfy { agentMachineRowShown($0, windowID: windowID) }
        var snapshotParams = params
        snapshotParams["window"] = .string(windowID)
        let snapshot = await DebugWindowSnapshot.captureAsync(snapshotParams, services: services)
        guard case .object(var result) = snapshot else { return snapshot }
        shown = result["error"] == nil
        result["scene"] = .string(definition.name)
        result["description"] = .string(definition.description)
        result["settled_ms"] = settled.map(CmuxNextSettings.JSONValue.number) ?? .null
        result["frames"] = frameStats
        result["leaked"] = .bool(leaked)
        result["scene_action"] = report
        return .object(result)
    }

    static func sceneWorkspace(_ machineID: String) -> String { "ws-\(machineID)" }

    /// Takes a cloud-agent-machines picture away, whatever is left of it (a Cloud refresh may have
    /// taken the machines already). Stateless: each render is a new registry.
    func endAgentCloudMachines() {
        let removed = Self.sceneMachineIDs.compactMap { services.machines.remove($0) }
        for session in removed { session.disconnect() }
        if !removed.isEmpty { services.windows.reconcileMembership() }
    }

    /// Row `key` in `windowID`'s sidebar list, as the list laid it out; nil until the list has it.
    func agentMachineRow(_ key: SidebarRowKey, windowID: String) -> SidebarDebugRow? {
        guard let sidebar = services.windows.controller(for: windowID)?.sidebar.container.sidebarView else { return nil }
        let wanted = String(describing: key)
        return sidebar.debugRows().rows.first { $0.key == wanted }
    }

    /// The sidebar list's scroll view and its visible part (top-left window points); nil while hidden.
    func agentMachineVisibleList(windowID: String) -> (scroll: NSScrollView, visible: CGRect)? {
        guard let controller = services.windows.controller(for: windowID) else { return nil }
        let sidebar = controller.sidebar.container.sidebarView
        guard !sidebar.isHiddenOrHasHiddenAncestor, sidebar.window != nil, !sidebar.visibleRect.isEmpty,
              let scroll = Self.agentMachineScrollView(in: sidebar), !scroll.isHiddenOrHasHiddenAncestor else { return nil }
        let height = controller.window?.contentView?.bounds.height ?? 0
        let clip = scroll.contentView.convert(scroll.contentView.bounds, to: nil).intersection(sidebar.convert(sidebar.visibleRect, to: nil))
        guard !clip.isEmpty else { return nil }
        return (scroll, CGRect(x: clip.minX, y: height - clip.maxY, width: clip.width, height: clip.height))
    }

    /// Whether row `key` is drawn: in the list, sized, not suppressed or faded, its middle in the visible part.
    func agentMachineRowShown(_ key: SidebarRowKey, windowID: String) -> Bool {
        guard let row = agentMachineRow(key, windowID: windowID), let list = agentMachineVisibleList(windowID: windowID) else { return false }
        return row.inList && !row.suppressed && row.windowFrame.height > 0 && (row.viewAlpha ?? 0) > 0
            && list.visible.contains(CGPoint(x: row.windowFrame.midX, y: row.windowFrame.midY))
    }

    /// Scrolls the list so every scene machine's row the list has shows.
    func scrollToAgentMachines(windowID: String) {
        guard let list = agentMachineVisibleList(windowID: windowID), let document = list.scroll.documentView,
              let height = services.windows.controller(for: windowID)?.window?.contentView?.bounds.height else { return }
        let frames = Self.sceneMachineIDs.compactMap { agentMachineRow(.workspace(WorkspaceID(Self.sceneWorkspace($0))), windowID: windowID)?.windowFrame }
        guard let first = frames.first else { return }
        let union = frames.dropFirst().reduce(first) { $0.union($1) }
        document.scrollToVisible(document.convert(CGRect(x: union.minX, y: height - union.maxY, width: union.width, height: union.height), from: nil))
        list.scroll.reflectScrolledClipView(list.scroll.contentView)
    }

    static func agentMachineScrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        return view.subviews.lazy.compactMap(agentMachineScrollView(in:)).first
    }

    /// What each machine got to: its workspace in its store and in the daemon order, the window that
    /// took it, the sidebar model listing it, and its row laid out and drawn.
    func agentMachinesReport(windowID: String) -> CmuxNextSettings.JSONValue {
        let registry = services.windows.registry.value
        let listed = Set(services.windows.controller(for: windowID)?.sidebar.model.sections.flatMap(\.workspaces).map(\.id.rawValue) ?? [])
        return .array(Self.sceneMachineIDs.map { id in
            let ws = Self.sceneWorkspace(id), session = services.machines.session(id)
            let ordered = session.map { WindowManager.orderedIDs(of: $0.daemon, machines: services.machines).contains(ws) } ?? false
            let row = SidebarRowKey.workspace(WorkspaceID(ws))
            return .object([
                "machine": .string(id), "in_store": .bool(session?.daemon.store.workspace(id: ws) != nil), "in_order": .bool(ordered),
                "window": registry.owner(of: ws).map { .string($0 == windowID ? "scene" : "other") } ?? .string("none"),
                "listed": .bool(listed.contains(ws)),
                "row": .string(agentMachineRowShown(row, windowID: windowID) ? "drawn" : agentMachineRow(row, windowID: windowID) != nil ? "laid out" : "none"),
            ])
        })
    }

    /// One line of ``agentMachinesReport(windowID:)`` for an error a capture prints.
    static func summary(_ report: CmuxNextSettings.JSONValue) -> String {
        guard case .array(let machines) = report else { return "" }
        return machines.compactMap { machine -> String? in
            guard case .object(let m) = machine else { return nil }
            let field = { (key: String) in m[key].map { value -> String in
                if case .string(let text) = value { return text }
                if case .bool(let flag) = value { return flag ? "yes" : "no" }
                return "?"
            } ?? "?" }
            return "\(field("machine")): store \(field("in_store")), order \(field("in_order")), window \(field("window")), listed \(field("listed")), row \(field("row"))"
        }.joined(separator: "; ")
    }

    /// The three running, connected machines, each with one workspace: the person's my-project, and
    /// the image's own workspace-1 on each machine an agent made.
    func addAgentCloudMachines() {
        let api = services.cloud.api, binary = URL(fileURLWithPath: "/usr/bin/false")
        let paths = CloudPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent("cn-capture-cloud-machines"))
        let hub = CloudTunnelHub(api: api, paths: paths, binary: binary, deviceName: "capture")
        for (id, name, workspace) in [(Self.openedMachineID, "my-vm", "my-project"), (Self.agentMachineIDs[0], "lane-vm-1", "workspace-1"),
                                      (Self.agentMachineIDs[1], "test-vm-2", "workspace-1")] {
            let link = CloudMachineLink(machineID: id, api: api, hub: hub, paths: paths, binary: binary, deviceName: "capture")
            let session = CloudMachineSession(machine: CloudMachine(id: id, status: .running, displayName: name), link: link,
                                              mainWork: services.mainWork)
            services.machines.add(session)
            // Connected, as the account's list leaves a running machine: a connecting one draws no rows.
            _ = session.daemon.store.apply(.connected(DaemonIdentity(registryID: "s-\(id)", generation: "capture"),
                                                      generationChanged: false))
            session.daemon.store.apply(snapshot: DaemonTree(registryID: "s-\(id)", workspaces: [
                WorkspaceSnapshot(id: WorkspaceHandle(rawValue: 1), key: WorkspaceKey(rawValue: Self.sceneWorkspace(id)), name: workspace),
            ]))
        }
        services.windows.reconcileMembership()
    }
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
        let settled = await frames.settled(until: ready, start: ContinuousClock.now, window: 100, deadline: 20_000)
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
        let page = view?.debugCaptureState
        let sidebarRow = services.windows.controller(for: windowID)?.sidebar.model.sections.flatMap(\.workspaces)
            .first(where: { $0.id.rawValue == workspace.id })
        let sidebarRowMatches = sidebarRow?.title == expected
        let pending = sidebarRow?.rowState.isPending == true
        let ready = workspace.name == expected && workspace.nameSource == expectedSource
            && tabFound && sessionOK && hostKnown && generatedOK && page?.ready == true && sidebarRowMatches && !pending
        let diagnostic = "name=\(workspace.name),source=\(workspace.nameSource.rawValue),expected=\(expected),tabFound=\(tabFound),sessionOK=\(sessionOK),hostKnown=\(hostKnown),generatedOK=\(generatedOK),actualGenerated=\(actualGeneratedPreview),sidebarRow=\(sidebarRowMatches),pending=\(pending),\(page?.diagnostic ?? "no view")"
        return (ready, String(diagnostic.prefix(420)))
    }
}

/// Leo 2026-10-29: "a whole lot of this cloud stuff ought to get better...". A Cloud machine that ran
/// for hours and lost its app link read "Failed to start" in red. This scene shows two machine
/// headers through the real connect path, with no network: a running machine whose link went down
/// (the app server's `cmux.cloud.link_down`, the error a dropped link ends with), and one whose
/// connect the provider refused. Each machine has a workspace, as a machine that ran does.
extension CaptureSceneRegistry {
    static let cloudMachineDisconnectedScene = "cloud-machine-disconnected"
    /// The machine whose link dropped, then the one whose connect the provider refused, with each one's connect error.
    static let endedLinkMachines: [(id: String, name: String, code: String, message: String)] = [
        ("capture-vm-dropped", "dropped-link-vm", "cmux.cloud.link_down", "the machine's link went down"),
        ("capture-vm-refused", "refused-vm", "vm_start_failed", "the provider could not start this machine"),
    ]

    /// Shows the settled showcase window's sidebar, adds both machines with a header per computer
    /// (`sidebar.groupByComputer`, as `DebugCloudMachineFixture` does), connects each so its link
    /// ends, waits until the list lays out both headers, scrolls to them (they follow This Mac's rows,
    /// maybe below the fold), waits until both draw inside the list's visible part, and snapshots the
    /// window. The capture driver takes its own light and dark stills (`debug.window_snapshot`) after
    /// this returns, so a pictured render keeps the machines and the setting until the next render
    /// (``endCloudMachineDisconnected()``); a failure, a cancelled wait included, takes them away at
    /// once. Nothing claims the machines' workspaces for a window (a header draws without rows), so
    /// no claim outlives the scene. A header that never draws fails the scene: the check reads
    /// the drawn rows (`SidebarView.debugRows`) of a sidebar that shows, never only the model.
    func renderCloudMachineDisconnected(_ params: [String: CmuxNextSettings.JSONValue], definition: CaptureSceneDefinition,
                                        windowID: String) async -> CmuxNextSettings.JSONValue {
        let ids = Self.endedLinkMachines.map(\.id)
        guard let controller = services.windows.controller(for: windowID) else {
            return .object(["error": .string("no window for the Cloud machine headers"), "scene": .string(definition.name)])
        }
        // A saved hidden or collapsed sidebar would keep its rows mounted but out of the picture.
        controller.sidebar.restore(width: 300, hidden: false)
        endCloudMachineDisconnected()
        var shown = false
        defer { if !shown { endCloudMachineDisconnected() } }
        // Machine headers draw only with a section per computer.
        DesignSettings.shared.sidebarSections.groupsByComputer = true
        for machine in Self.endedLinkMachines {
            let (code, message) = (machine.code, machine.message)
            let resolver = CloudConnectOpResolver(run: { _, _, _, _ in throw CloudAppOpError(code: code, message: message) })
            let session = CloudMachineSession(machine: CloudMachine(id: machine.id, status: .running, displayName: machine.name),
                                              appLink: CloudLinkSession(key: CloudLinkKey(machine: machine.id), resolver: resolver),
                                              localIdentity: { nil }, mainWork: services.mainWork)
            services.machines.add(session)
            // The tree a machine that ran leaves: connected once, with a workspace.
            _ = session.daemon.store.apply(.connected(DaemonIdentity(registryID: "s-\(machine.id)", generation: "capture"),
                                                      generationChanged: false))
            session.daemon.store.apply(snapshot: DaemonTree(registryID: "s-\(machine.id)", workspaces: [
                WorkspaceSnapshot(id: WorkspaceHandle(rawValue: 1), key: WorkspaceKey(rawValue: "ws-\(machine.id)"), name: "workspace-1"),
            ]))
            // A click's connect: its `cloud.machine.connect` fails, and the link ends.
            session.connect(origin: .user)
        }
        services.windows.reconcileMembership()
        // Checked each frame: both links ended and the list laid out both headers.
        frames.start()
        let listed = await frames.settled(until: { [self] in
            ids.allSatisfy { services.machines.session($0)?.linkEnded != nil && endedLinkHeader($0, windowID: windowID) != nil }
        }, start: ContinuousClock.now, window: 100, deadline: 10_000)
        _ = frames.stop()
        if listed != nil { scrollToEndedLinkHeaders(ids, windowID: windowID) }
        frames.start()
        var settled: Double?
        if listed != nil {
            settled = await frames.settled(until: { [self] in ids.allSatisfy { endedLinkHeaderShown($0, windowID: windowID) } },
                                           start: ContinuousClock.now, window: 300, deadline: 3_000)
        }
        let frameStats = frames.stop()
        let report = endedLinkReport(windowID: windowID)
        guard settled != nil else {
            return .object(["error": .string(listed == nil ? "the Cloud machine headers never reached the sidebar list with their ended link"
                                                           : "the Cloud machine headers never drew in the sidebar's visible part"),
                            "scene": .string(definition.name), "scene_action": report, "frames": frameStats])
        }
        var snapshotParams = params
        snapshotParams["window"] = .string(windowID)
        let snapshot = await DebugWindowSnapshot.captureAsync(snapshotParams, services: services)
        guard case .object(var result) = snapshot else { return snapshot }
        shown = result["error"] == nil
        result["scene"] = .string(definition.name)
        result["description"] = .string(definition.description)
        result["settled_ms"] = settled.map(CmuxNextSettings.JSONValue.number) ?? .null
        result["frames"] = frameStats
        result["scene_action"] = report
        return .object(result)
    }

    /// Takes a shown cloud-machine-disconnected picture away: whichever of its machines are still
    /// listed, and the grouping setting it turned on, back to the settings' own value (as
    /// `DebugCloudMachineFixture` derives it). Unconditional and with no saved state:
    /// `debug.scene.render` makes a new registry each call, and a Cloud reconcile may already have
    /// taken the machines away while the setting is still forced on.
    func endCloudMachineDisconnected() {
        var removed = false
        for id in Self.endedLinkMachines.map(\.id) {
            guard let session = services.machines.remove(id) else { continue }
            session.disconnect()
            removed = true
        }
        if removed { services.windows.reconcileMembership() }
        DesignSettings.shared.sidebarSections.groupsByComputer = (services.settings?.snapshot.sidebarSections ?? .defaults).groupsByComputer
    }

    /// Machine `id`'s header row in `windowID`'s sidebar list, as the list laid it out (drawn or
    /// not); nil until the list has it.
    func endedLinkHeader(_ id: String, windowID: String) -> SidebarDebugRow? {
        guard let sidebar = services.windows.controller(for: windowID)?.sidebar.container.sidebarView else { return nil }
        let key = String(describing: SidebarRowKey.section(.machine(MachineID(id))))
        return sidebar.debugRows().rows.first { $0.key == key }
    }

    /// The sidebar list's scroll view in `windowID`, and its visible part in top-left window points
    /// (as `SidebarDebugRow.windowFrame` is): the clip view's bounds within the sidebar's own visible
    /// rect. Nil while the sidebar or a parent is hidden, or nothing of the list is visible.
    func endedLinkVisibleList(windowID: String) -> (scroll: NSScrollView, visible: CGRect)? {
        guard let controller = services.windows.controller(for: windowID) else { return nil }
        let sidebar = controller.sidebar.container.sidebarView
        guard !sidebar.isHiddenOrHasHiddenAncestor, sidebar.window != nil, !sidebar.visibleRect.isEmpty,
              let scroll = Self.endedLinkScrollView(in: sidebar), !scroll.isHiddenOrHasHiddenAncestor else { return nil }
        let height = controller.window?.contentView?.bounds.height ?? 0
        let clip = scroll.contentView.convert(scroll.contentView.bounds, to: nil)
            .intersection(sidebar.convert(sidebar.visibleRect, to: nil))
        guard !clip.isEmpty else { return nil }
        return (scroll, CGRect(x: clip.minX, y: height - clip.maxY, width: clip.width, height: clip.height))
    }

    /// Whether machine `id`'s header is drawn: the sidebar shows (``endedLinkVisibleList(windowID:)``),
    /// the header's row view is in the list, has a size, is neither suppressed nor faded out, and its
    /// middle is inside the list's visible part.
    func endedLinkHeaderShown(_ id: String, windowID: String) -> Bool {
        guard let row = endedLinkHeader(id, windowID: windowID), let list = endedLinkVisibleList(windowID: windowID) else { return false }
        return row.inList && !row.suppressed && row.windowFrame.height > 0 && (row.viewAlpha ?? 0) > 0
            && list.visible.contains(CGPoint(x: row.windowFrame.midX, y: row.windowFrame.midY))
    }

    /// Scrolls the sidebar list so every header in `ids` shows.
    func scrollToEndedLinkHeaders(_ ids: [String], windowID: String) {
        guard let list = endedLinkVisibleList(windowID: windowID), let document = list.scroll.documentView,
              let height = services.windows.controller(for: windowID)?.window?.contentView?.bounds.height else { return }
        let rows = ids.compactMap { endedLinkHeader($0, windowID: windowID)?.windowFrame }
        guard let first = rows.first else { return }
        let union = rows.dropFirst().reduce(first) { $0.union($1) }
        // Top-left window points to the bottom-left ones AppKit converts from.
        let inWindow = CGRect(x: union.minX, y: height - union.maxY, width: union.width, height: union.height)
        document.scrollToVisible(document.convert(inWindow, from: nil))
        list.scroll.reflectScrolledClipView(list.scroll.contentView)
    }

    /// The first scroll view under `view` (the sidebar's list).
    static func endedLinkScrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        return view.subviews.lazy.compactMap(endedLinkScrollView(in:)).first
    }

    /// Each machine's header status and detail as the sidebar holds them, its ended link, and whether its header draws.
    func endedLinkReport(windowID: String) -> CmuxNextSettings.JSONValue {
        let headers = services.windows.controller(for: windowID)?.sidebar.model.sections.compactMap(\.machine) ?? []
        return .array(Self.endedLinkMachines.map { machine in
            let header = headers.first { $0.id.rawValue == machine.id }
            return .object([
                "machine": .string(machine.id),
                "status": header.map { CmuxNextSettings.JSONValue.string(String(describing: $0.status)) } ?? .null,
                "detail": header?.detail.map(CmuxNextSettings.JSONValue.string) ?? .null,
                "link_ended": services.machines.session(machine.id)?.linkEnded.map(CmuxNextSettings.JSONValue.string) ?? .null,
                "laid_out": .bool(endedLinkHeader(machine.id, windowID: windowID) != nil),
                "drawn": .bool(endedLinkHeaderShown(machine.id, windowID: windowID)),
            ])
        })
    }
}
#endif
