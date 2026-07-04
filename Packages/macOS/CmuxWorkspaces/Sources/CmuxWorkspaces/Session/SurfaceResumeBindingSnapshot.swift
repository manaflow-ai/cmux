public import Foundation
import CMUXAgentLaunch

/// The persisted surface-resume binding: the Codable wire payload recording the
/// command (plus its kind/source/cwd/environment/approval metadata) cmux replays
/// when restoring a terminal surface across launches.
///
/// The wire format (`CodingKeys`, optional-field decoding, and normalization in
/// `init`) is frozen; restore reads snapshots written by older builds, so field
/// shapes and defaulting must stay byte-identical.
nonisolated public struct SurfaceResumeBindingSnapshot: Codable, Equatable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case name
        case kind
        case command
        case cwd
        case checkpointId
        case source
        case environment
        case autoResume
        case approvalPolicy
        case approvalRecordId
        case updatedAt
    }

    /// Display name of the binding, for example `tmux main`.
    public var name: String?
    /// The binding kind, for example `tmux` or `hermes-agent`.
    public var kind: String?
    /// The shell command restored for this binding.
    public var command: String
    /// The working directory associated with the restored command.
    public var cwd: String?
    /// Optional checkpoint identifier (for example the tmux session name).
    public var checkpointId: String?
    /// The binding source, for example `agent-hook`, `cli`, or `process-detected`.
    public var source: String?
    /// Environment values restored with the command (sensitive keys stripped).
    public var environment: [String: String]?
    /// Whether the binding was explicitly configured for automatic resume.
    public var autoResume: Bool?
    /// The approval disposition recorded for this binding.
    public var approvalPolicy: SurfaceResumeApprovalPolicy?
    /// Identifier of the approval record that authorized this binding, if any.
    public var approvalRecordId: String?
    /// When this binding was last updated, as seconds since the Unix epoch.
    public var updatedAt: TimeInterval

    /// Creates a normalized binding snapshot, sanitizing the command, cwd,
    /// source, and environment exactly as the persisted wire format requires.
    public init(
        name: String? = nil,
        kind: String? = nil,
        command: String,
        cwd: String? = nil,
        checkpointId: String? = nil,
        source: String? = nil,
        environment: [String: String]? = nil,
        autoResume: Bool? = nil,
        approvalPolicy: SurfaceResumeApprovalPolicy? = nil,
        approvalRecordId: String? = nil,
        updatedAt: TimeInterval = Date().timeIntervalSince1970
    ) {
        let normalizedCwd = Self.normalized(cwd)
        let normalizedSource = Self.normalized(source)
        self.name = Self.normalized(name)
        self.kind = Self.normalized(kind)
        self.command = Self.sanitizedStartupCommand(
            command,
            cwd: normalizedCwd,
            source: normalizedSource
        )
        self.cwd = normalizedCwd
        self.checkpointId = Self.normalized(checkpointId)
        self.source = normalizedSource
        self.environment = Self.normalizedEnvironment(environment)
        self.autoResume = autoResume
        self.approvalPolicy = approvalPolicy
        self.approvalRecordId = Self.normalized(approvalRecordId)
        self.updatedAt = updatedAt
    }

    /// Decodes a binding from a persisted snapshot, defaulting `updatedAt` for
    /// legacy snapshots written before the field existed.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            name: try container.decodeIfPresent(String.self, forKey: .name),
            kind: try container.decodeIfPresent(String.self, forKey: .kind),
            command: try container.decode(String.self, forKey: .command),
            cwd: try container.decodeIfPresent(String.self, forKey: .cwd),
            checkpointId: try container.decodeIfPresent(String.self, forKey: .checkpointId),
            source: try container.decodeIfPresent(String.self, forKey: .source),
            environment: try container.decodeIfPresent([String: String].self, forKey: .environment),
            autoResume: try container.decodeIfPresent(Bool.self, forKey: .autoResume),
            approvalPolicy: try container.decodeIfPresent(SurfaceResumeApprovalPolicy.self, forKey: .approvalPolicy),
            approvalRecordId: try container.decodeIfPresent(String.self, forKey: .approvalRecordId),
            updatedAt: try container.decodeIfPresent(TimeInterval.self, forKey: .updatedAt)
                ?? Date().timeIntervalSince1970
        )
    }

    /// Whether this binding came from a process detector.
    public var isProcessDetected: Bool {
        source == "process-detected"
    }

    /// Whether this binding came from a managed agent hook.
    public var isAgentHookBinding: Bool {
        source == "agent-hook"
    }

    /// Whether this binding came from the CLI.
    public var isCLIBinding: Bool {
        source == "cli"
    }

    /// Whether this binding permits automatic resume without prompting.
    public var allowsAutomaticResume: Bool {
        autoResume == true
    }

    /// Returns a copy of this agent-hook binding retargeted to a new working
    /// directory (#7155): the `cwd` is updated and the startup command's
    /// required `cd` prefix is rewritten. Non-agent-hook bindings are returned
    /// unchanged.
    public func retargetingWorkingDirectory(_ workingDirectory: String?) -> SurfaceResumeBindingSnapshot {
        guard isAgentHookBinding else { return self }
        let normalizedCwd = Self.normalized(workingDirectory)
        let retargetedCommand = TerminalStartupWorkingDirectoryPrefix()
            .replacingRequiredChangeDirectoryPrefix(in: command, workingDirectory: normalizedCwd)
        return SurfaceResumeBindingSnapshot(
            name: name,
            kind: kind,
            command: retargetedCommand,
            cwd: normalizedCwd,
            checkpointId: checkpointId,
            source: source,
            environment: environment,
            autoResume: autoResume,
            approvalPolicy: approvalPolicy,
            approvalRecordId: approvalRecordId,
            updatedAt: updatedAt
        )
    }

    /// Whether a stored binding (`self`) should yield to a freshly detected one,
    /// reproducing the legacy reconcile precedence.
    public func shouldYieldToDetectedSurfaceResumeBinding(_ detectedBinding: SurfaceResumeBindingSnapshot) -> Bool {
        detectedBinding.isProcessDetected && (isProcessDetected || isAgentHookBinding)
    }

    /// Maximum inline startup-input byte length before the command is written to
    /// a launcher script instead of being inlined. Mirrors the app's
    /// `SessionRestorableAgentSnapshot.maxInlineStartupInputBytes` (900); the two
    /// are kept equal so the inline-vs-script cutover matches the agent restore
    /// path exactly.
    public static let maxInlineStartupInputBytes = 900

    /// The startup input replayed for this binding (the inline form).
    public var startupInput: String? {
        inlineStartupInput
    }

    /// The startup input as a single interactive-shell line, wrapping the command
    /// in `/usr/bin/env <assignments> /bin/zsh -lc` when environment is present.
    public var inlineStartupInput: String? {
        let trimmed = startupCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let environment, !environment.isEmpty else {
            return trimmed + "\n"
        }
        let assignments = environment.keys.sorted().compactMap { key -> String? in
            guard let value = environment[key] else { return nil }
            return "\(key)=\(value)"
        }
        let argv = ["/usr/bin/env"] + assignments + ["/bin/zsh", "-lc", trimmed]
        return argv.map(Self.shellSingleQuoted).joined(separator: " ") + "\n"
    }

    private var startupCommand: String {
        Self.sanitizedStartupCommand(command, cwd: cwd, source: source)
    }

    private static func sanitizedStartupCommand(
        _ command: String,
        cwd: String?,
        source: String?
    ) -> String {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard source == "agent-hook" else { return trimmed }
        return TerminalStartupWorkingDirectoryPrefix().replacingRequiredChangeDirectoryPrefix(
            in: trimmed,
            workingDirectory: cwd
        )
    }

    /// Returns the startup input used to replay this binding in an interactive
    /// shell, falling back to a launcher script when the inline form exceeds
    /// ``maxInlineStartupInputBytes``.
    public func startupInputWithLauncherScript(
        fileManager: FileManager = .default,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory,
        allowLauncherScript: Bool = true
    ) -> String? {
        guard let inlineInput = inlineStartupInput else { return nil }
        guard inlineInput.utf8.count > Self.maxInlineStartupInputBytes else {
            return inlineInput
        }
        guard allowLauncherScript else { return inlineInput }
        guard let scriptURL = SurfaceResumeBindingScriptStore.writeLauncherScript(
            inlineInput: inlineInput,
            binding: self,
            fileManager: fileManager,
            temporaryDirectory: temporaryDirectory
        ) else {
            return nil
        }

        let scriptInput = "/bin/zsh \(Self.shellSingleQuoted(scriptURL.path))\n"
        return scriptInput.utf8.count <= Self.maxInlineStartupInputBytes ? scriptInput : nil
    }

    /// Returns a launcher command used when the restored terminal should run a
    /// command and then return to the login shell.
    public func startupCommandWithLauncherScript(
        fileManager: FileManager = .default,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) -> String? {
        guard let inlineInput = inlineStartupInput,
              let scriptURL = SurfaceResumeBindingScriptStore.writeLauncherScript(
                  inlineInput: inlineInput,
                  binding: self,
                  fileManager: fileManager,
                  temporaryDirectory: temporaryDirectory,
                  returnToLoginShell: true
              ) else {
            return nil
        }
        return "/bin/zsh \(Self.shellSingleQuoted(scriptURL.path))"
    }

    private static func normalized(_ rawValue: String?) -> String? {
        guard let rawValue = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawValue.isEmpty else {
            return nil
        }
        return rawValue
    }

    private static func normalizedEnvironment(_ environment: [String: String]?) -> [String: String]? {
        guard let environment else { return nil }
        let normalized = environment.reduce(into: [String: String]()) { result, item in
            let key = item.key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty, !isSensitiveEnvironmentKey(key) else { return }
            guard isSafeEnvironmentValue(item.value) else { return }
            result[key] = item.value
        }
        return normalized.isEmpty ? nil : normalized
    }

    private static func isSafeEnvironmentValue(_ value: String) -> Bool {
        !value.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F }
    }

    private static func isSensitiveEnvironmentKey(_ key: String) -> Bool {
        let uppercasedKey = key.uppercased()
        let sensitiveFragments = [
            "API_KEY",
            "ACCESS_KEY",
            "AUTH_TOKEN",
            "BEARER_TOKEN",
            "PRIVATE_KEY",
            "PASSWORD",
            "PASSWD",
            "SECRET",
            "TOKEN",
            "CREDENTIAL",
            "COOKIE",
        ]
        return sensitiveFragments.contains { uppercasedKey.contains($0) }
    }

    private static func shellSingleQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

extension SurfaceResumeBindingSnapshot: WorkspaceSurfaceResumeBinding {
    /// Whether this binding's approval policy requires prompting.
    public var requiresPromptApproval: Bool {
        approvalPolicy == .prompt
    }
}

/// Conforms the persisted binding snapshot to the resolution seam so
/// `SessionRestoreCoordinator` can decide stored-vs-process-detected outcomes.
/// Both witnesses (`isProcessDetected`, `shouldYieldToDetectedSurfaceResumeBinding(_:)`)
/// are already declared on the struct above, so the conformance is satisfied as-is.
extension SurfaceResumeBindingSnapshot: SurfaceResumeBindingResolving {}

/// Writes (and prunes) the temporary launcher scripts a surface-resume binding
/// falls back to when its inline startup input exceeds
/// ``SurfaceResumeBindingSnapshot/maxInlineStartupInputBytes``.
private enum SurfaceResumeBindingScriptStore {
    private static let directoryName = "cmux-surface-resume"
    private static let scriptTTL: TimeInterval = 24 * 60 * 60

    static func writeLauncherScript(
        inlineInput: String,
        binding: SurfaceResumeBindingSnapshot,
        fileManager: FileManager,
        temporaryDirectory: URL,
        returnToLoginShell: Bool = false
    ) -> URL? {
        let directoryURL = temporaryDirectory.appendingPathComponent(directoryName, isDirectory: true)
        do {
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directoryURL.path)
            pruneOldScripts(in: directoryURL, fileManager: fileManager)

            let prefix = safeFilenamePrefix(binding: binding)
            let scriptURL = directoryURL.appendingPathComponent(
                "\(prefix)-\(UUID().uuidString).zsh",
                isDirectory: false
            )
            var lines = [
                "#!/bin/zsh",
                "rm -f -- \"$0\" 2>/dev/null || true"
            ]
            if returnToLoginShell {
                lines.append(contentsOf: TerminalStartupReturnShellScript().commandThenReturnLines(
                    command: inlineInput,
                    workingDirectory: binding.cwd
                ))
            } else {
                lines.append(inlineInput)
            }
            let contents = lines.joined(separator: "\n") + "\n"
            try contents.write(to: scriptURL, atomically: true, encoding: .utf8)
            try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)
            return scriptURL
        } catch {
            return nil
        }
    }

    private static func safeFilenamePrefix(binding: SurfaceResumeBindingSnapshot) -> String {
        let rawPrefix = binding.kind ?? binding.source ?? "surface-resume"
        let safePrefix = rawPrefix
            .prefix(24)
            .map { character -> Character in
                character.isLetter || character.isNumber || character == "-" ? character : "_"
            }
        return safePrefix.isEmpty ? "surface-resume" : String(safePrefix)
    }

    private static func pruneOldScripts(in directoryURL: URL, fileManager: FileManager) {
        guard let scriptURLs = try? fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }
        let cutoff = Date().addingTimeInterval(-scriptTTL)
        for scriptURL in scriptURLs where scriptURL.pathExtension == "zsh" {
            guard let values = try? scriptURL.resourceValues(forKeys: [.contentModificationDateKey]),
                  let modifiedAt = values.contentModificationDate,
                  modifiedAt < cutoff else {
                continue
            }
            try? fileManager.removeItem(at: scriptURL)
        }
    }
}
