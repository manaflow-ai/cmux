public import Foundation
import CmuxNextDaemon

/// The agent memory index through the `optchat-chief` this build bundles
/// (Contents/Resources/bin): `agent-memory search --json --limit N -- QUERY`.
///
/// The tool reads `agents.memory.*` itself, so on a machine whose
/// `agents.memory.owner` names another, the owner answers. It inherits the
/// app's environment (`CMUX_NEXT_CONFIG_FILE` included), so a tagged build
/// reads the same settings file as the app.
public nonisolated struct BundledAgentMemoryIndex: AgentMemoryIndex {
    let executable: URL
    let timeout: Duration

    /// The bundled tool's file name, as `HomeBrainHost` names it.
    static let toolName = "optchat-chief"

    /// Creates an index over one tool executable.
    /// - Parameters:
    ///   - executable: The `optchat-chief` to run; a missing file makes searches unsupported.
    ///   - timeout: The longest one search may take. Defaults to 25 seconds, under the
    ///     supervisor's 30-second provider deadline, so a slow owner relay ends here first.
    public init(executable: URL, timeout: Duration = .seconds(25)) {
        self.executable = executable
        self.timeout = timeout
    }

    /// The tool in this app bundle's `Contents/Resources/bin`, or nil when the build ships none (Release, RC).
    /// - Parameter resources: The bundle's resource folder.
    /// - Returns: An index over `bin/optchat-chief` when that file is executable.
    public static func bundled(resources: URL? = Bundle.main.resourceURL) -> BundledAgentMemoryIndex? {
        guard let tool = resources?.appendingPathComponent("bin", isDirectory: true).appendingPathComponent(toolName),
              FileManager.default.isExecutableFile(atPath: tool.path) else { return nil }
        return BundledAgentMemoryIndex(executable: tool)
    }

    public func search(query: String, limit: Int) async throws(AppHostCapabilityError) -> [AgentMemoryHit] {
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { throw .unsupported("memory.search") }
        let result: ProcessResult
        do {
            // `--` ends the options, so a query such as `--force` stays words.
            result = try await ProcessRunner.run(executable: executable,
                                                 arguments: ["agent-memory", "search", "--json", "--limit", String(limit), "--", query],
                                                 environment: nil, timeout: timeout, clock: ContinuousClock())
        } catch {
            if Task.isCancelled { throw cancelled() }
            throw unavailable(retryable: true)
        }
        // A cancelled call's child is killed; that exit is the cancellation, not an outage.
        if Task.isCancelled { throw cancelled() }
        guard result.status == 0, let hits = try? JSONDecoder().decode([AgentMemoryHit].self, from: result.stdout) else {
            throw unavailable(retryable: result.status != 0)
        }
        return hits
    }

    private func cancelled() -> AppHostCapabilityError {
        AppHostCapabilityError(code: "operation.cancelled",
                               message: String(localized: "apps.memory.search.cancelled", defaultValue: "The memory search was cancelled", bundle: .module))
    }

    private func unavailable(retryable: Bool) -> AppHostCapabilityError {
        AppHostCapabilityError(code: "memory.unavailable",
                               message: String(localized: "apps.memory.search.unavailable", defaultValue: "Agent memory search is unavailable", bundle: .module),
                               retryable: retryable)
    }
}
