import Foundation
import CoreFoundation

/// Recovers missing Codex resume permissions while preserving explicit launch settings.
///
/// Session selection and transcript I/O belong to the caller; this value only
/// interprets captured arguments and individual transcript records.
public struct CodexResumePermissionPolicy: Sendable {
    private let timestampFormat = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    /// Creates the permission recovery policy.
    public init() {}

    /// Reports whether a launch explicitly specifies any permission field.
    ///
    /// - Parameter launchCommand: The captured launch, including its launcher classification.
    /// - Returns: Whether approval, sandbox or workspace networking is explicitly set.
    public func hasExplicitPermissions(in launchCommand: AgentLaunchCommand?) -> Bool {
        let fields = permissionFields(launchCommand)
        return fields.approval || fields.sandbox || fields.network
    }

    /// Reports whether transcript evidence could supply a missing effective field.
    ///
    /// - Parameter launchCommand: The captured launch to repair.
    /// - Returns: False when explicit settings make reading the transcript unnecessary.
    public func requiresTranscriptEvidence(for launchCommand: AgentLaunchCommand) -> Bool {
        guard !launchCommand.arguments.isEmpty else { return false }
        let fields = permissionFields(launchCommand)
        return !fields.approval || !fields.sandbox
            || (!fields.network && fields.sandboxMode == "workspace-write")
    }

    /// Adds recorded permission flags only for fields absent from the launch.
    ///
    /// - Parameters:
    ///   - launchCommand: The original launch whose explicit settings take precedence.
    ///   - permissionArguments: Permission flags recovered from a recorded turn.
    /// - Returns: A repaired capture preserving the other launch metadata.
    public func repairing(
        _ launchCommand: AgentLaunchCommand,
        with permissionArguments: [String]
    ) -> AgentLaunchCommand {
        guard !launchCommand.arguments.isEmpty, !permissionArguments.isEmpty else { return launchCommand }
        var launchCommand = launchCommand
        let explicit = permissionFields(launchCommand)
        /// Inserts recovered options before the prompt separator, preserving literal prompt arguments.
        func insertRecovered(_ arguments: [String]) {
            // Flags after `--` are prompt text, not Codex options.
            let index = launchCommand.arguments.firstIndex(of: "--") ?? launchCommand.arguments.endIndex
            launchCommand.arguments.insert(contentsOf: arguments, at: index)
        }
        let shortcut = permissionArguments.count == 1
            && ["--yolo", "--dangerously-bypass-approvals-and-sandbox"].contains(permissionArguments[0])
        if shortcut, !explicit.approval, !explicit.sandbox {
            insertRecovered(permissionArguments)
            return launchCommand
        }
        /// Reads the value following a recovered option, returning nil for absent or incomplete pairs.
        func inferredValue(_ option: String) -> String? {
            guard let index = permissionArguments.firstIndex(of: option),
                  index + 1 < permissionArguments.count else { return nil }
            return permissionArguments[index + 1]
        }
        let approval = shortcut ? "never" : inferredValue("-a")
        let sandbox = shortcut ? "danger-full-access" : inferredValue("-s")
        if !explicit.approval, let approval {
            insertRecovered(["-a", approval])
        }
        if !explicit.sandbox, let sandbox {
            insertRecovered(["-s", sandbox])
        }
        let effectiveSandbox = explicit.sandbox ? explicit.sandboxMode : sandbox
        if !explicit.network, effectiveSandbox == "workspace-write",
           let network = permissionArguments.first(where: { $0.hasPrefix("sandbox_workspace_write.network_access=") }) {
            insertRecovered(["-c", network])
        }
        return launchCommand
    }

    /// Reads permission arguments from a recorded turn before the capture time.
    ///
    /// - Parameters:
    ///   - line: A single transcript JSONL record.
    ///   - capturedAt: Exclusive upper bound for the turn timestamp.
    /// - Returns: Recorded permission flags, or nil for unrelated or unusable records.
    public func permissionArguments(
        from line: Data,
        before capturedAt: TimeInterval
    ) -> [String]? {
        guard !line.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              object["type"] as? String == "turn_context",
              let timestamp = object["timestamp"] as? String,
              let payload = object["payload"] as? [String: Any] else {
            return nil
        }
        guard let date = try? timestampFormat.parse(timestamp), date.timeIntervalSince1970 < capturedAt else {
            return nil
        }
        let approvalPolicy = normalizedValue(payload["approval_policy"] as? String)
        let sandboxPolicy = payload["sandbox_policy"] as? [String: Any]
        let sandboxMode = sandboxPolicy.flatMap {
            normalizedValue($0["type"] as? String)
        }
        if approvalPolicy == "never", sandboxMode == "danger-full-access" {
            return ["--yolo"]
        }
        if approvalPolicy == "never", sandboxMode == "disabled" {
            return ["--dangerously-bypass-approvals-and-sandbox"]
        }
        var arguments: [String] = []
        if let approvalPolicy {
            arguments.append(contentsOf: ["-a", approvalPolicy])
        }
        if let sandboxMode,
           ["read-only", "workspace-write", "danger-full-access"].contains(sandboxMode) {
            arguments.append(contentsOf: ["-s", sandboxMode])
        }
        // JSON numbers also bridge to Bool. Replay only an actual recorded Boolean,
        // preserving both true and false without inventing a missing policy.
        if sandboxMode == "workspace-write",
           let networkAccess = sandboxPolicy?["network_access"] as? NSNumber,
           CFGetTypeID(networkAccess) == CFBooleanGetTypeID() {
            arguments.append(contentsOf: [
                "-c",
                "sandbox_workspace_write.network_access=\(networkAccess.boolValue ? "true" : "false")",
            ])
        }
        return arguments.isEmpty ? nil : arguments
    }

    /// Identifies explicitly supplied fields and resolves flag-over-config sandbox precedence.
    ///
    /// Argument parsing stops at the prompt separator. Unrecognized parent-table syntax
    /// remains authoritative so recovery cannot guess over an explicit override.
    private func permissionFields(
        _ launchCommand: AgentLaunchCommand?
    ) -> (approval: Bool, sandbox: Bool, network: Bool, sandboxMode: String?) {
        guard let launchCommand,
              AgentLaunchCaptureTrust.launcherDescribesKind(launchCommand.launcher, kind: "codex") else {
            return (false, false, false, nil)
        }
        let arguments = launchCommand.arguments
        var approval = false
        var sandbox = false
        var network = false
        var sandboxFlag: String?
        var sandboxConfig: String?
        var fullAuto = false
        var bypass = false
        for (index, argument) in arguments.enumerated() {
            if argument == "--" { break }
            if ["--yolo", "--dangerously-bypass-approvals-and-sandbox"].contains(argument) {
                approval = true
                sandbox = true
                bypass = true
            }
            if argument == "--full-auto" {
                approval = true
                sandbox = true
                fullAuto = true
            }
            if argument == "-a" || argument == "--ask-for-approval"
                || argument.hasPrefix("--ask-for-approval=")
                || (argument.hasPrefix("-a") && argument.count > 2) {
                approval = true
            }
            if argument == "-s" || argument == "--sandbox" {
                sandbox = true
                if index + 1 < arguments.count { sandboxFlag = arguments[index + 1] }
            } else if argument.hasPrefix("--sandbox=") {
                sandbox = true
                sandboxFlag = String(argument.dropFirst("--sandbox=".count))
            } else if argument.hasPrefix("-s"), argument.count > 2 {
                sandbox = true
                sandboxFlag = String(argument.dropFirst(argument.hasPrefix("-s=") ? 3 : 2))
            }
            if let config = configOverride(in: arguments, at: index) {
                let parts = config.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard let rawKey = parts.first else { continue }
                switch rawKey.trimmingCharacters(in: .whitespacesAndNewlines) {
                case "approval_policy":
                    approval = true
                case "sandbox_mode":
                    sandbox = true
                    if parts.count == 2 {
                        sandboxConfig = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
                            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                    }
                case "sandbox_workspace_write.network_access":
                    network = true
                case "sandbox_workspace_write":
                    let keys = parts.count == 2
                        ? CodexInlineTableKeyParser().parse(String(parts[1])) : nil
                    // Preserve unparseable overrides. A valid roots-only table
                    // does not specify network policy; string values are not keys.
                    network = network || (keys?.contains("network_access") ?? true)
                default:
                    break
                }
            }
        }
        // Match Codex's flag-over-config precedence independently of argv order.
        let mode = bypass ? "danger-full-access"
            : sandboxFlag ?? (fullAuto ? "workspace-write" : sandboxConfig)
        return (approval, sandbox, network, mode)
    }

    /// Extracts split, compact or equals-form Codex config overrides without interpreting their values.
    private func configOverride(in arguments: [String], at index: Int) -> String? {
        let argument = arguments[index]
        if argument == "-c" || argument == "--config" {
            return index + 1 < arguments.count ? arguments[index + 1] : nil
        }
        for prefix in ["--config=", "-c=", "-c"] where argument.hasPrefix(prefix) {
            return String(argument.dropFirst(prefix.count))
        }
        return nil
    }


    /// Trims a recorded policy string and treats blank values as absent evidence.
    private func normalizedValue(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
