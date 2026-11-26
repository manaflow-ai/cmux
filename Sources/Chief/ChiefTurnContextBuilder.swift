import CmuxChief
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
    /// The memory state each conversation's brain session started with.
    let freshness = ChiefMemoryFreshness()

    /// The context of one turn.
    func context(for input: ChiefTurnContextInput) async -> ChiefTurnContext {
        let (socketPath, workspaces) = await MainActor.run { (Self.activeSocketPath(), Self.workspacesSummary()) }
        let settings = await engine()
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
            dangerouslySkipPermissions: settings.dangerouslySkipPermissions)
        prompt.apply(memory.snapshot())
        let preamble = await freshness.preamble(for: input.conversation, freshSession: input.resumeSession == nil,
                                                current: ChiefMemoryState(memory: memory))
        return ChiefTurnContext(systemPrompt: ChiefSystemPrompt(context: prompt).build(),
                                workingDirectory: FileManager.default.homeDirectoryForCurrentUser,
                                environment: Self.environment(socketPath: socketPath, home: input.home),
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
    /// `CMUX_WORKSPACE_ID`): this app's socket, its bundled CLI first on
    /// `PATH`, the Chief home for `cmux chief memory`, and `CMUX_CHIEF_TURN`, so a note the
    /// turn saves is recorded as saved by Chief (source `chief`), one typed in a terminal as
    /// saved from the command line (`cli`). `CMUX_SOCKET`, an
    /// older override the CLI also honors, is pinned to the same socket so an
    /// inherited value never points the Chief at another cmux.
    static func environment(socketPath: String, home: ChiefHome,
                            base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var environment: [String: String] = [
            "CMUX_SOCKET_PATH": socketPath,
            ChiefHome.environmentKey: home.root.path,
            "CMUX_CHIEF_TURN": "1",
        ]
        if base["CMUX_SOCKET"] != nil { environment["CMUX_SOCKET"] = socketPath }
        var path = (base["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin").split(separator: ":").map(String.init)
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
