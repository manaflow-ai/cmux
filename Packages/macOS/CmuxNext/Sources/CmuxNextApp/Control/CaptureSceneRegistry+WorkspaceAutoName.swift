#if DEBUG || CMUX_BENCH_HOOKS
import AppKit
import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextSettings
import CmuxNextWorkspaceNaming

/// A real daemon workspace and agent tab for before/after auto-name captures.
extension CaptureSceneRegistry {
    static let workspaceAutoNameScene = "workspace-auto-name"
    private static let autoNameSession = "mock-session"
    private static let firstAutoName = "First chat title"
    private static let generatedAutoName = "Updated chat title"

    func renderWorkspaceAutoName(_ params: [String: JSONValue], definition: CaptureSceneDefinition,
                                 windowID: String) async -> JSONValue {
        guard let connection = services.daemon.connection,
              let controller = services.windows.controller(for: windowID) else {
            return .object(["error": .string("auto-name scene has no daemon or window"), "scene": .string(definition.name)])
        }
        do {
            let key = WorkspaceKey.generate()
            _ = try await connection.createWorkspace(key: key)
            services.windows.claimNew(workspaceID: key.rawValue, window: windowID)
            guard let pane = await services.daemon.store.firstPane(mirroring: key),
                  let workspace = services.daemon.store.workspace(key: key) else {
                return .object(["error": .string("auto-name workspace has no mirrored pane"), "scene": .string(definition.name)])
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
            // The fixture supplies an acpmux summary. Only the production namer may write its title.
            let summary: [String: Any] = ["sessionId": Self.autoNameSession, "title": Self.generatedAutoName, "titleSource": "generated"]
            let title = AgentTurnStates.title(summary)
            let generatedTitle = AgentTurnStates.title(summary, includingPrompt: false)
            AgentTurnStateStore.shared.apply(session: Self.autoNameSession, state: nil, lastMessage: nil, muted: false,
                                              title: title, generatedTitle: generatedTitle, detail: nil, recordsTimeline: false)
            let expected = WorkspaceAutoNameWiring(services: services).reader.rule.persistedName(
                name: Self.firstAutoName, title: nil, front: .chat(userName: nil, title: title, generatedTitle: generatedTitle),
                isLocalMachine: true, supportsNameSource: true, alreadyRenamed: false,
                nameSource: .auto, nameRevision: firstRevision, allowsLegacyDefaults: false) ?? Self.firstAutoName
            let (settled, frameStats) = await autoNameSettled {
                self.autoNameReady(workspace: workspace, tabID: created.key, windowID: windowID, expected: expected)
            }
            var report: [String: JSONValue] = [
                "scene": .string(definition.name), "description": .string(definition.description),
                "workspace": .string(workspace.id), "tab": .string(created.key),
                "first_name": .string(Self.firstAutoName), "first_name_revision": .number(Double(firstRevision)),
                "workspace_name": .string(workspace.name), "workspace_name_source": .string(workspace.nameSource.rawValue),
                "workspace_name_revision": .number(Double(workspace.nameRevision)),
                "generated_title": generatedTitle.map(JSONValue.string) ?? .null,
                "expected_name": .string(expected), "frames": frameStats,
            ]
            guard let settled else {
                report["error"] = .string("auto-name scene did not settle before deadline")
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
    private func autoNameSettled(_ ready: @escaping () -> Bool) async -> (Double?, JSONValue) {
        frames.start()
        let settled = await frames.settled(until: ready, start: ContinuousClock.now, window: 100, deadline: 10_000)
        return (settled, frames.stop())
    }

    private func autoNameReady(workspace: WorkspaceModel, tabID: String, windowID: String, expected: String) -> Bool {
        guard workspace.name == expected, workspace.nameSource == .auto,
              let tab = workspace.screens.flatMap(\.panes).flatMap(\.tabs).first(where: { $0.id == tabID }),
              let session = tab.agentSession, session.session == Self.autoNameSession,
              AgentTurnStateStore.shared.generatedTitle(for: session) == Self.generatedAutoName,
              let view = services.agentTabs.existingView(tabID), view.model.hasPainted,
              view.webView.window != nil, !view.webView.isLoading,
              let sidebar = services.windows.controller(for: windowID)?.sidebar.model else { return false }
        return sidebar.sections.flatMap(\.workspaces).contains {
            $0.id.rawValue == workspace.id && $0.title == expected && !$0.rowState.isPending
        }
    }
}
#endif
