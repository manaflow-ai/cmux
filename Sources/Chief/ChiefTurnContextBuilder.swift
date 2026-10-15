import CmuxChief
import CmuxSettings
import Foundation

/// Builds each Chief turn's ``ChiefTurnContext``: the system prompt from
/// ``ChiefSystemPrompt`` and ``ChiefMemory``, the user's home directory as the
/// working directory, and the environment that lets the brain drive this
/// cmux through its bundled CLI.
struct ChiefTurnContextBuilder: Sendable {
    /// The settings of the brain that will answer (the prompt names it).
    let engine: @Sendable () async -> ChiefEngineSettings

    /// The context of one turn.
    func context(for input: ChiefTurnContextInput) async -> ChiefTurnContext {
        let socketPath = await MainActor.run { Self.activeSocketPath() }
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
            chiefHomePath: input.home.root.path)
        prompt.apply(memory.snapshot())
        return ChiefTurnContext(systemPrompt: ChiefSystemPrompt.build(context: prompt),
                                workingDirectory: FileManager.default.homeDirectoryForCurrentUser,
                                environment: Self.environment(socketPath: socketPath, home: input.home))
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
    /// `PATH`, and the Chief home for `cmux chief memory`. `CMUX_SOCKET`, an
    /// older override the CLI also honors, is pinned to the same socket so an
    /// inherited value never points the Chief at another cmux.
    static func environment(socketPath: String, home: ChiefHome,
                            base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var environment: [String: String] = [
            "CMUX_SOCKET_PATH": socketPath,
            ChiefHome.environmentKey: home.root.path,
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
