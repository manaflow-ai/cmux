import Foundation

/// Captured launch command for a restorable agent session: the launcher token,
/// resolved executable, argv, working directory, and selected environment, plus
/// optional capture metadata. Persisted as part of a session snapshot, so its
/// `Codable` shape is wire/Defaults compatible and must stay stable.
public struct AgentLaunchCommandSnapshot: Codable, Equatable, Sendable {
    /// Launcher identifier (e.g. `claude`, `codex`, `opencode`, or a custom registration id).
    public var launcher: String?
    /// Resolved executable path the agent was launched with, when known.
    public var executablePath: String?
    /// Full argument vector the agent was launched with.
    public var arguments: [String]
    /// Working directory the agent was launched from, when known.
    public var workingDirectory: String?
    /// Selected environment variables retained for relaunch, when any.
    public var environment: [String: String]?
    /// Capture timestamp (`timeIntervalSince1970`), when recorded.
    public var capturedAt: TimeInterval?
    /// Origin of the capture (e.g. `process`), when recorded.
    public var source: String?

    /// Memberwise initializer matching the legacy synthesized shape: optional
    /// fields default to `nil`, `arguments` is required.
    public init(
        launcher: String? = nil,
        executablePath: String? = nil,
        arguments: [String],
        workingDirectory: String? = nil,
        environment: [String: String]? = nil,
        capturedAt: TimeInterval? = nil,
        source: String? = nil
    ) {
        self.launcher = launcher
        self.executablePath = executablePath
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.environment = environment
        self.capturedAt = capturedAt
        self.source = source
    }
}

extension AgentLaunchCommandSnapshot {
    /// Builds a snapshot for a process-detected agent: selects the retained
    /// environment via ``AgentLaunchEnvironmentPolicy``, preserving the live
    /// `PATH` for `opencode`, and records `source` as `"process"`.
    public init(
        processDetectedLauncher launcher: String,
        executablePath: String?,
        arguments: [String],
        workingDirectory: String?,
        environment: [String: String]
    ) {
        var selectedEnvironment = AgentLaunchEnvironmentPolicy.selectedEnvironment(from: environment, kind: launcher)
        if launcher == "opencode",
           let path = environment["PATH"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !path.isEmpty {
            selectedEnvironment["PATH"] = path
        }
        self.init(
            launcher: launcher,
            executablePath: executablePath,
            arguments: arguments,
            workingDirectory: workingDirectory,
            environment: selectedEnvironment.isEmpty ? nil : selectedEnvironment,
            capturedAt: nil,
            source: "process"
        )
    }
}
