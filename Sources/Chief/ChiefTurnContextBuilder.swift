import CmuxChief
import CmuxHomeCore
import CmuxSettings
import Foundation

/// Builds each Chief turn's ``ChiefTurnContext``: the system prompt from
/// ``ChiefSystemPrompt`` and ``ChiefMemory`` (with the app's workspaces),
/// the user's home directory as the working directory, the environment that
/// lets the brain drive this cmux through its bundled CLI, and a
/// `<memory-update>` preamble when memory changed since the brain session
/// started (``ChiefMemoryFreshness``; the prompt only reaches a brain then).
struct ChiefTurnContextBuilder: Sendable {
    /// The settings of the brain that will answer (the prompt names it).
    let engine: @Sendable () async -> ChiefEngineSettings
    /// The user's login-shell `PATH`, nil when it could not be read.
    var loginShellPath: @Sendable () async -> String? = { await ChiefLoginShellPath.shared.value() }
    /// The memory state each conversation's brain session started with.
    let freshness = ChiefMemoryFreshness()

    /// The context of one turn.
    func context(for input: ChiefTurnContextInput) async -> ChiefTurnContext {
        let (socketPath, workspaces, target) = await MainActor.run {
            (Self.activeSocketPath(), Self.workspacesSummary(), Self.chiefTarget(conversation: input.conversation))
        }
        let settings = await engine()
        let loginShellPath = await loginShellPath()
        let memory = ChiefMemory(paths: ChiefMemoryPaths(home: input.home))
        // Missing profile files are written once; a failure leaves the prompt without them.
        try? memory.ensureDefaults()
        var prompt = ChiefPromptContext(
            userDisplayName: Self.userDisplayName,
            harness: settings.resolvedHarness.displayName,
            model: settings.resolvedModel,
            cmuxVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            socketPath: socketPath,
            chiefHomePath: input.home.root.path,
            workspacesSummary: workspaces,
            currentWorkspaceRef: target?.workspaceRef,
            currentSurfaceRef: target?.surfaceRef,
            dangerouslySkipPermissions: settings.dangerouslySkipPermissions)
        prompt.apply(memory.snapshot())
        let preamble = await freshness.preamble(for: input.conversation, freshSession: input.resumeSession == nil,
                                                current: ChiefMemoryState(memory: memory))
        return ChiefTurnContext(systemPrompt: ChiefSystemPrompt(context: prompt).build(),
                                workingDirectory: FileManager.default.homeDirectoryForCurrentUser,
                                environment: Self.environment(socketPath: socketPath, home: input.home,
                                                            workspaceID: target?.workspaceID, surfaceID: target?.surfaceID,
                                                            loginShellPath: loginShellPath),
                                engine: ChiefTurnEngine(harness: settings.resolvedHarness.rawValue, model: settings.resolvedModel,
                                                        effort: settings.effort.isEmpty ? nil : settings.effort),
                                turnPreamble: preamble)
    }

    /// Every window's workspaces as ``ChiefWorkspacesSummary`` lines, with
    /// the refs the `cmux` CLI accepts; nil before session restore settles
    /// (the window tree is not safe to walk until then) or with no workspace.
    @MainActor
    static func workspacesSummary() -> String? {
        guard let app = AppDelegate.shared, app.didCompleteInitialSessionRestore else { return nil }
        let controller = TerminalController.shared
        let notifications = TerminalNotificationStore.shared
        var lines: [ChiefWorkspacesSummary.Line] = []
        for window in app.listMainWindowSummaries() {
            guard let tabManager = app.tabManagerFor(windowId: window.windowId) else { continue }
            let windowRef = controller.v2EnsureHandleRef(kind: .window, uuid: window.windowId)
            for workspace in tabManager.tabs {
                let unread = notifications.unreadCount(forTabId: workspace.id) > 0
                let status = ChiefAgentGlance.status(lifecycles: workspace.agentLifecycleStatesByPanelId, unread: unread)
                lines.append(ChiefWorkspacesSummary.Line(
                    windowRef: windowRef,
                    ref: controller.v2EnsureHandleRef(kind: .workspace, uuid: workspace.id),
                    // The name the user sees on Home ("Home folder", never a bare "~"), so Chief's
                    // replies name the workspace as the user's lists do.
                    title: ChiefAgentGlance.displayTitle(customTitle: workspace.customTitle, title: workspace.title,
                                                         currentDirectory: workspace.currentDirectory),
                    directory: workspace.currentDirectory,
                    agentState: status.map(agentWord),
                    isSelected: tabManager.selectedTabId == workspace.id))
            }
        }
        return ChiefWorkspacesSummary(lines: lines).render()
    }

    /// Resolves the mounted Chief pane for this turn. Chief is a native panel,
    /// so its panel id is also the stable surface id understood by the socket.
    /// Prefer the exact conversation, then the canonical Home pane for the
    /// default conversation. This never uses the visually focused workspace.
    @MainActor
    static func chiefTarget(conversation: ConversationID) ->
        (workspaceID: UUID, surfaceID: UUID, workspaceRef: String, surfaceRef: String)? {
        guard let app = AppDelegate.shared, app.didCompleteInitialSessionRestore else { return nil }
        var exact: [(Workspace, ChiefPanel)] = []
        var home: [(Workspace, ChiefPanel)] = []
        for window in app.listMainWindowSummaries() {
            guard let manager = app.tabManagerFor(windowId: window.windowId) else { continue }
            for workspace in manager.tabs {
                for panel in workspace.panels.values {
                    guard let chief = panel as? ChiefPanel else { continue }
                    if chief.conversationID == conversation { exact.append((workspace, chief)) }
                    if chief.isHome { home.append((workspace, chief)) }
                }
            }
        }
        let candidate = exact.first ?? home.first
        guard let (workspace, chief) = candidate else { return nil }
        let controller = TerminalController.shared
        return (
            workspace.id,
            chief.id,
            controller.v2EnsureHandleRef(kind: .workspace, uuid: workspace.id),
            controller.v2EnsureHandleRef(kind: .surface, uuid: chief.id)
        )
    }

    /// The summary's word for an agent status (model-facing, not localized).
    static func agentWord(_ status: ChiefAgentGlance.Status) -> String {
        switch status {
        case .needsYou: "needs input"
        case .done: "done, unread"
        case .working: "working"
        case .idle: "idle"
        }
    }

    /// The user's full name, nil when the account has none.
    static var userDisplayName: String? {
        let name = NSFullUserName().trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    /// The socket this app listens on now.
    @MainActor
    static func activeSocketPath() -> String {
        TerminalController.shared.activeSocketPath(preferredPath: SocketControlSettings.socketPath())
    }

    /// The bundled `cmux` CLI, nil when the build has none.
    static var bundledCLI: URL? {
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("bin/cmux"),
              FileManager.default.isExecutableFile(atPath: url.path) else { return nil }
        return url
    }

    /// What the brain's process gets on top of the app's environment (the
    /// brain's launcher already drops `CMUX_SURFACE_ID` and
    /// `CMUX_WORKSPACE_ID`): this app's socket, a `PATH` with the user's
    /// login-shell directories (``ChiefSearchPath``) and the bundled CLI
    /// first, the Chief home for `cmux chief memory`, and `CMUX_CHIEF_TURN`, so a note the
    /// turn saves is recorded as saved by Chief (source `chief`), one typed in a terminal as
    /// saved from the command line (`cli`). `CMUX_SOCKET`, an
    /// older override the CLI also honors, is pinned to the same socket so an
    /// inherited value never points the Chief at another cmux.
    static func environment(socketPath: String, home: ChiefHome,
                            workspaceID: UUID? = nil, surfaceID: UUID? = nil, loginShellPath: String? = nil,
                            base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var environment: [String: String] = [
            "CMUX_SOCKET_PATH": socketPath,
            ChiefHome.environmentKey: home.root.path,
            "CMUX_CHIEF_TURN": "1",
        ]
        if let workspaceID { environment["CMUX_WORKSPACE_ID"] = workspaceID.uuidString }
        if let surfaceID { environment["CMUX_SURFACE_ID"] = surfaceID.uuidString }
        if base["CMUX_SOCKET"] != nil { environment["CMUX_SOCKET"] = socketPath }
        var path = ChiefSearchPath(home: FileManager.default.homeDirectoryForCurrentUser.path)
            .merged(base: base["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin", loginShell: loginShellPath)
            .split(separator: ":").map(String.init)
        if let cli = bundledCLI {
            environment["CMUX_BUNDLED_CLI_PATH"] = cli.path
            let bin = cli.deletingLastPathComponent().path
            path.removeAll { $0 == bin }
            path.insert(bin, at: 0)
        }
        environment["PATH"] = path.joined(separator: ":")
        return environment
    }
}
