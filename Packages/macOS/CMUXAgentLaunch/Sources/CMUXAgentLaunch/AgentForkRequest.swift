import Foundation

/// Primitive input for constructing one shell-free fork invocation.
///
/// The request deliberately carries no app or registry types. Callers map
/// their persisted snapshot/registration models into this value, then share
/// the same launcher, built-in, and custom-template rules everywhere.
public struct AgentForkRequest: Sendable, Equatable {
    /// A registry fork template after its metadata has been reduced to values.
    public struct CustomTemplate: Sendable, Equatable {
        /// The template containing `{{executable}}`, `{{sessionId}}`, and related tokens.
        public let command: String
        /// The executable used when the captured launch has no argv[0].
        public let defaultExecutable: String
        /// The optional persisted session directory, already expanded by the caller.
        public let sessionDirectory: String?

        /// Creates a custom fork template.
        public init(
            command: String,
            defaultExecutable: String,
            sessionDirectory: String? = nil
        ) {
            self.command = command
            self.defaultExecutable = defaultExecutable
            self.sessionDirectory = sessionDirectory
        }
    }

    /// Agent kind used for built-in fork rules.
    public let kind: String
    /// Checkpoint/session identifier embedded in the fork argv.
    public let checkpointID: String
    /// Captured launch metadata, when available.
    public let launchCommand: AgentLaunchCommand?
    /// Destination working directory used by custom `{{cwd}}` templates.
    public let workingDirectory: String?
    /// Captured Claude permission mode, when applicable.
    public let observedPermissionMode: String?
    /// Whether the kind is a custom registration and must not use built-in fallbacks.
    public let isCustomKind: Bool
    /// Optional registry-owned template.
    public let customTemplate: CustomTemplate?

    /// Creates one fork planning request.
    public init(
        kind: String,
        checkpointID: String,
        launchCommand: AgentLaunchCommand? = nil,
        workingDirectory: String? = nil,
        observedPermissionMode: String? = nil,
        isCustomKind: Bool = false,
        customTemplate: CustomTemplate? = nil
    ) {
        self.kind = kind
        self.checkpointID = checkpointID
        self.launchCommand = launchCommand
        self.workingDirectory = workingDirectory
        self.observedPermissionMode = observedPermissionMode
        self.isCustomKind = isCustomKind
        self.customTemplate = customTemplate
    }

    /// Builds sanitized argv, or `nil` when no safe fork form is available.
    public func forkArguments() -> [String]? {
        let forkArgv = AgentForkArgv()
        switch forkArgv.launcherResolution(
            launcher: launchCommand?.launcher,
            sessionId: checkpointID,
            executablePath: launchCommand?.executablePath,
            arguments: launchCommand?.arguments ?? []
        ) {
        case .resolved(let argv):
            return argv
        case .passthrough:
            break
        }

        if let customTemplate {
            let arguments = templateArguments(customTemplate)
            return arguments.isEmpty ? nil : arguments
        }
        if isCustomKind {
            return nil
        }
        return forkArgv.builtInKind(
            kind: kind,
            sessionId: checkpointID,
            executablePath: launchCommand?.executablePath,
            arguments: launchCommand?.arguments ?? [],
            observedPermissionMode: observedPermissionMode
        )
    }

    private func templateArguments(_ template: CustomTemplate) -> [String] {
        let originalExecutable = commandExecutable(fallbackExecutable: template.defaultExecutable)
        return AgentLaunchTemplateRenderer().arguments(
            template: template.command,
            executable: originalExecutable,
            sessionID: checkpointID,
            workingDirectory: workingDirectory ?? launchCommand?.workingDirectory,
            sessionDirectory: template.sessionDirectory
        ) ?? []
    }

    private func commandExecutable(fallbackExecutable: String) -> String {
        let arguments = launchCommand?.arguments ?? []
        return normalized(launchCommand?.executablePath)
            ?? normalized(arguments.first)
            ?? fallbackExecutable
    }

    private func normalized(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }
}
