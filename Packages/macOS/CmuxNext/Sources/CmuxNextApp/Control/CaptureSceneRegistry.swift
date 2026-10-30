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
        // A cloud-agent-machines picture stays for the capture's stills; any next render ends it.
        endAgentCloudMachines()
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
                    return Self.agentPageCanSettle(attached: view.webView.window != nil,
                                                   loading: view.webView.isLoading,
                                                   chromium: view.debugShowsChromium)
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

        // The sidebar is its picture: the showcase window, then the machines, with no agent turn.
        if definition.name == Self.cloudAgentMachinesScene || definition.name == Self.cloudAgentMachinesLeakedScene {
            return await renderAgentCloudMachines(params, definition: definition, windowID: targetWindowID,
                                                  expectsRows: definition.name == Self.cloudAgentMachinesLeakedScene)
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
        CaptureSceneDefinition(name: "cloud-agent-machines",
                               description: "Two running Cloud machines an agent or a lane-pool tool made, never opened here, each with its image's own workspace; their headers must draw and their workspaces list nowhere (the after of #27884)."),
        CaptureSceneDefinition(name: "cloud-agent-machines-leaked",
                               description: "cloud-agent-machines that also fails unless each machine's workspace draws a row (the before of #27884)."),
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

/// Leo 2026-10-29, on agents' Cloud machines in his sidebar: "why is there all this weird stuff at the
/// bottom of the sidebar". The account's machine list connects every Cloud machine, and each starts
/// with a workspace from its image: this scene adds two such machines, as that list would.
extension CaptureSceneRegistry {
    static let cloudAgentMachinesScene = "cloud-agent-machines"
    static let agentMachineIDs = ["capture-vm-lane-1", "capture-vm-test-2"]

    static let cloudAgentMachinesLeakedScene = "cloud-agent-machines-leaked"

    /// Adds the machines to the settled showcase window with a header per computer, so each machine
    /// draws its header whether or not a window took its workspace, scrolls them into view, and
    /// snapshots the window once both headers are drawn and each machine's workspace row is drawn
    /// (`expectsRows`, the before) or listed nowhere (the after). Anything else fails, and the error names what each machine got to:
    /// a still that missed it would prove nothing. Cleanup runs on every exit.
    func renderAgentCloudMachines(_ params: [String: CmuxNextSettings.JSONValue], definition: CaptureSceneDefinition,
                                  windowID: String, expectsRows: Bool) async -> CmuxNextSettings.JSONValue {
        guard let controller = services.windows.controller(for: windowID) else {
            return .object(["error": .string("no window"), "scene": .string(definition.name)])
        }
        controller.sidebar.restore(width: 300, hidden: false)
        // The capture driver takes its light and dark stills (debug.window_snapshot) after this
        // returns: the machines stay until the next render. A failure takes them away at once.
        endAgentCloudMachines()
        var shown = false
        defer { if !shown { endAgentCloudMachines(always: true) } }
        DesignSettings.shared.sidebarSections.groupsByComputer = true
        _ = addAgentCloudMachines()
        let done = { [self] in
            Self.agentMachineIDs.allSatisfy { id in
                agentMachineRow(.section(.machine(MachineID(id))), windowID: windowID) != nil
                    && (agentMachineRow(.workspace(WorkspaceID("ws-\(id)")), windowID: windowID) != nil) == expectsRows
            }
        }
        frames.start()
        let listed = await frames.settled(until: done, start: ContinuousClock.now, window: 100, deadline: 10_000)
        _ = frames.stop()
        scrollToAgentMachines(windowID: windowID)
        frames.start()
        var settled: Double?
        let pictured = { [self] in
            Self.agentMachineIDs.allSatisfy { id in
                let row = SidebarRowKey.workspace(WorkspaceID("ws-\(id)"))
                return agentMachineRowShown(.section(.machine(MachineID(id))), windowID: windowID)
                    && (expectsRows ? agentMachineRowShown(row, windowID: windowID)
                        : agentMachineRow(row, windowID: windowID) == nil && services.windows.registry.value.owner(of: "ws-\(id)") == nil)
            }
        }
        if listed != nil {
            settled = await frames.settled(until: pictured, start: ContinuousClock.now, window: 300, deadline: 3_000)
        }
        let frameStats = frames.stop()
        let report = agentMachinesReport(windowID: windowID)
        // Checked again in the snapshot's own turn: the settle window must not have moved it.
        guard settled != nil, pictured() else {
            let want = expectsRows ? "headers and rows" : "headers without rows"
            return .object(["error": .string("\(definition.name): \(want) \(listed == nil ? "never listed" : "never drew in view") [\(Self.summary(report))]"),
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

    /// Takes a shown cloud-agent-machines picture away: the machines, and the grouping setting it
    /// forced, back to the settings' own value. Stateless (each render is a new registry): a
    /// picture is shown while its machines are in the registry.
    /// `always`: the scene's own failure, which forced the setting whether or not its machines are still there.
    func endAgentCloudMachines(always: Bool = false) {
        guard always || Self.agentMachineIDs.contains(where: { services.machines.session($0) != nil }) else { return }
        removeAgentCloudMachines()
        DesignSettings.shared.sidebarSections.groupsByComputer = (services.settings?.snapshot.sidebarSections ?? .defaults).groupsByComputer
    }

    func removeAgentCloudMachines() {
        for id in Self.agentMachineIDs { services.machines.remove(id)?.disconnect() }
        services.windows.reconcileMembership()
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

    /// Scrolls the list so every machine header (and its row, when listed) shows.
    func scrollToAgentMachines(windowID: String) {
        guard let list = agentMachineVisibleList(windowID: windowID), let document = list.scroll.documentView,
              let height = services.windows.controller(for: windowID)?.window?.contentView?.bounds.height else { return }
        let keys: [SidebarRowKey] = Self.agentMachineIDs.flatMap { [.section(.machine(MachineID($0))), .workspace(WorkspaceID("ws-\($0)"))] }
        let frames = keys.compactMap { agentMachineRow($0, windowID: windowID)?.windowFrame }
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
    /// took it, the sidebar model listing it, and its header and row laid out and drawn.
    func agentMachinesReport(windowID: String) -> CmuxNextSettings.JSONValue {
        let registry = services.windows.registry.value
        let listed = Set(services.windows.controller(for: windowID)?.sidebar.model.sections.flatMap(\.workspaces).map(\.id.rawValue) ?? [])
        return .array(Self.agentMachineIDs.map { id in
            let ws = "ws-\(id)", session = services.machines.session(id)
            let ordered = session.map { WindowManager.orderedIDs(of: $0.daemon, machines: services.machines).contains(ws) } ?? false
            let header = SidebarRowKey.section(.machine(MachineID(id))), row = SidebarRowKey.workspace(WorkspaceID(ws))
            return .object([
                "machine": .string(id), "in_store": .bool(session?.daemon.store.workspace(id: ws) != nil), "in_order": .bool(ordered),
                "window": registry.owner(of: ws).map { .string($0 == windowID ? "scene" : "other") } ?? .string("none"),
                "listed": .bool(listed.contains(ws)),
                "header": .string(agentMachineRowShown(header, windowID: windowID) ? "drawn" : agentMachineRow(header, windowID: windowID) != nil ? "laid out" : "none"),
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
            return "\(field("machine")): store \(field("in_store")), order \(field("in_order")), window \(field("window")), listed \(field("listed")), header \(field("header")), row \(field("row"))"
        }.joined(separator: "; ")
    }

    func addAgentCloudMachines() -> CmuxNextSettings.JSONValue {
        let api = services.cloud.api, binary = URL(fileURLWithPath: "/usr/bin/false")
        let paths = CloudPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent("cn-capture-cloud-machines"))
        let hub = CloudTunnelHub(api: api, paths: paths, binary: binary, deviceName: "capture")
        for (id, name) in zip(Self.agentMachineIDs, ["lane-vm-1", "test-vm-2"]) {
            let link = CloudMachineLink(machineID: id, api: api, hub: hub, paths: paths, binary: binary, deviceName: "capture")
            let session = CloudMachineSession(machine: CloudMachine(id: id, status: .running, displayName: name), link: link,
                                              mainWork: services.mainWork)
            services.machines.add(session)
            // Connected, as the account's list leaves a running machine: a connecting one draws no rows.
            _ = session.daemon.store.apply(.connected(DaemonIdentity(registryID: "s-\(id)", generation: "capture"),
                                                      generationChanged: false))
            session.daemon.store.apply(snapshot: DaemonTree(registryID: "s-\(id)", workspaces: [
                WorkspaceSnapshot(id: WorkspaceHandle(rawValue: 1), key: WorkspaceKey(rawValue: "ws-\(id)"), name: "workspace-1"),
            ]))
        }
        services.windows.reconcileMembership()
        return .number(Double(Self.agentMachineIDs.count))
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
        let inWindow = view?.webView.window != nil
        let loading = view?.webView.isLoading == true
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
