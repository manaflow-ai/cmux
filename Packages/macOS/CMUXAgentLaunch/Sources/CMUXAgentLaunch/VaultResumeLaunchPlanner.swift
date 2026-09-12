import Foundation

/// Plans a Vault entry into one canonical restore-verb launch or a bounded fallback.
public struct VaultResumeLaunchPlanner: Sendable {
    private let acceptedCodexApprovalPolicies: Set<String> = [
        "untrusted",
        "on-request",
        "never",
    ]
    private let registrationParser: VaultResumeRegistrationParser
    private let registrationTemplate: VaultResumeRegistrationTemplate
    private let resumeArgv: AgentResumeArgv

    /// Creates a stateless Vault launch planner.
    public init() {
        registrationParser = VaultResumeRegistrationParser()
        registrationTemplate = VaultResumeRegistrationTemplate()
        resumeArgv = AgentResumeArgv()
    }

    /// Plans a request without touching app state, process globals, or the filesystem.
    ///
    /// Structured plans are admitted only after the restore selector, launch
    /// argv, and registration environment have all passed the package's
    /// validation rules. A rendered command is retained solely as the explicit
    /// compatibility result when that construction fails.
    ///
    /// - Parameter request: Immutable Vault metadata and its legacy command.
    /// - Returns: A restore or compatibility plan, or `nil` when no safe startup input exists.
    public func plan(
        for request: VaultResumeLaunchRequest
    ) -> VaultResumeLaunchPlan? {
        let kind = normalized(request.kind)
        let sessionID = normalized(request.sessionID)
        guard let kind, let sessionID else {
            return compatibilityPlan(
                request: request,
                reason: request.profile.isRegistered
                    ? .unrepresentableRegistration
                    : .missingStructuredSnapshot
            )
        }

        let workingDirectory = effectiveWorkingDirectory(for: request)
        let components = components(for: request)
        guard components.isSupported else {
            return compatibilityPlan(request: request, reason: components.failureReason)
        }
        guard let selectorKind = AgentRestoreCLIArgument(rawValue: kind),
              AgentRestoreCLIArgument(rawValue: sessionID) != nil else {
            return compatibilityPlan(
                request: request,
                reason: request.profile.isRegistered
                    ? .unrepresentableRegistration
                    : .missingStructuredSnapshot
            )
        }
        let preparedArguments = preparedArguments(
            for: components,
            kind: kind,
            sessionID: sessionID,
            workingDirectory: workingDirectory
        )
        guard !preparedArguments.isEmpty else {
            return compatibilityPlan(request: request, reason: .unavailableStructuredArguments)
        }

        let snapshot = VaultResumeLaunchPlan.StructuredSnapshot(
            kind: selectorKind.rawValue,
            sessionID: sessionID,
            workingDirectory: workingDirectory,
            launchArguments: components.launchArguments,
            environment: components.environment,
            registration: components.registration,
            permissionMode: components.permissionMode,
            preparedResumeArguments: preparedArguments
        )
        return VaultResumeLaunchPlan(
            strategy: .restoreVerb,
            posixCommand: " \(restoreCommand(kind: selectorKind.rawValue, sessionID: sessionID))",
            workingDirectory: workingDirectory,
            structuredSnapshot: snapshot,
            legacyFallbackReason: nil
        )
    }

    private struct Components: Sendable {
        let launchArguments: [String]
        let environment: [String: String]
        let registration: VaultResumeLaunchRequest.Registration?
        let permissionMode: String?
        let isSupported: Bool
        let failureReason: VaultResumeLaunchPlan.LegacyFallbackReason
    }

    /// Builds provider-specific launch metadata before resume arguments are applied.
    private func components(for request: VaultResumeLaunchRequest) -> Components {
        switch request.profile {
        case let .claude(model, permissionMode, configDirectory):
            var arguments = ["claude"]
            if let model = nonEmpty(model) {
                arguments.append(contentsOf: ["--model", model])
            }
            let environment = nonEmpty(configDirectory).map {
                ["CLAUDE_CONFIG_DIR": $0]
            } ?? [:]
            return Components(
                launchArguments: arguments,
                environment: environment,
                registration: nil,
                permissionMode: nonEmpty(permissionMode),
                isSupported: true,
                failureReason: .missingStructuredSnapshot
            )
        case let .codex(model, approvalPolicy, sandboxMode, effort):
            var arguments = ["codex"]
            if let model = nonEmpty(model) {
                arguments.append(contentsOf: ["-m", model])
            }
            arguments.append(contentsOf: codexApprovalSandboxArgumentTokens(
                approvalPolicy: approvalPolicy,
                sandboxMode: sandboxMode
            ))
            if let effort = nonEmpty(effort) {
                arguments.append(contentsOf: ["-c", "model_reasoning_effort=\(effort)"])
            }
            return Components(
                launchArguments: arguments,
                environment: [:],
                registration: nil,
                permissionMode: nil,
                isSupported: true,
                failureReason: .missingStructuredSnapshot
            )
        case let .grok(model, permissionMode, sandboxMode, grokHome):
            var arguments = ["grok"]
            if let model = nonEmpty(model) {
                arguments.append(contentsOf: ["-m", model])
            }
            if let permissionMode = nonEmpty(permissionMode) {
                arguments.append(contentsOf: ["--permission-mode", permissionMode])
            }
            if let sandboxMode = nonEmpty(sandboxMode) {
                arguments.append(contentsOf: ["--sandbox", sandboxMode])
            }
            let environment = nonEmpty(grokHome).map { ["GROK_HOME": $0] } ?? [:]
            return Components(
                launchArguments: arguments,
                environment: environment,
                registration: nil,
                permissionMode: nil,
                isSupported: true,
                failureReason: .missingStructuredSnapshot
            )
        case let .opencode(providerModel, agentName):
            var arguments = ["opencode"]
            if let providerModel = nonEmpty(providerModel) {
                arguments.append(contentsOf: ["-m", providerModel])
            }
            if let agentName = nonEmpty(agentName) {
                arguments.append(contentsOf: ["--agent", agentName])
            }
            return Components(
                launchArguments: arguments,
                environment: [:],
                registration: nil,
                permissionMode: nil,
                isSupported: true,
                failureReason: .missingStructuredSnapshot
            )
        case .rovodev:
            return Components(
                launchArguments: ["acli", "rovodev", "run"],
                environment: [:],
                registration: nil,
                permissionMode: nil,
                isSupported: true,
                failureReason: .missingStructuredSnapshot
            )
        case let .hermesAgent(source, model, hermesHome):
            var arguments = ["hermes"]
            if source == "tui" {
                arguments.append("--tui")
            }
            if let model = nonEmpty(model) {
                arguments.append(contentsOf: ["--model", model])
            }
            let environment = nonEmpty(hermesHome).map { ["HERMES_HOME": $0] } ?? [:]
            return Components(
                launchArguments: arguments,
                environment: environment,
                registration: nil,
                permissionMode: nil,
                isSupported: true,
                failureReason: .missingStructuredSnapshot
            )
        case let .registered(registration, launchCommand):
            let parsed = registrationParser.parse(registration)
            let capturedArguments = launchCommand?.arguments ?? []
            let capturedEnvironment = launchCommand?.environment.map { environment in
                environment.reduce(into: [String: String]()) { result, item in
                    if let value = AgentLaunchEnvironmentPolicy()
                        .registrationEnvironmentValue(key: item.key, value: item.value) {
                        result[item.key] = value
                    }
                }
            }
            return Components(
                launchArguments: capturedArguments.isEmpty
                    ? [parsed.registration.defaultExecutable]
                    : capturedArguments,
                environment: parsed.environment.merging(capturedEnvironment ?? [:]) { _, capturedValue in
                    capturedValue
                },
                registration: parsed.registration,
                permissionMode: nil,
                isSupported: parsed.isSupported,
                failureReason: .unrepresentableRegistration
            )
        }
    }

    /// Computes the provider argv that the restore record will replay.
    private func preparedArguments(
        for components: Components,
        kind: String,
        sessionID: String,
        workingDirectory: String?
    ) -> [String] {
        let launchCommand = AgentLaunchCommand(
            arguments: components.launchArguments,
            workingDirectory: workingDirectory,
            environment: components.environment.isEmpty ? nil : components.environment,
            source: "vault"
        )
        if let registration = components.registration {
            if let registeredKind = registration.registeredResumeKind
                .flatMap({ RegisteredAgentResumeKind(rawValue: $0) }) {
                let arguments = resumeArgv.registeredBuiltInKind(
                    kind: registeredKind,
                    sessionId: sessionID,
                    executablePath: nil,
                    arguments: launchCommand.arguments
                ) ?? []
                if !arguments.isEmpty {
                    return arguments
                }
            }
            let arguments = registrationTemplate.resumeArguments(
                registration: registration,
                sessionID: sessionID,
                launchArguments: launchCommand.arguments,
                workingDirectory: workingDirectory
            )
            return arguments
        }
        return resumeArgv.builtInKind(
            kind: kind,
            sessionId: sessionID,
            executablePath: nil,
            arguments: launchCommand.arguments,
            observedPermissionMode: components.permissionMode
        ) ?? []
    }

    /// Builds the validated, shell-readable restore selector.
    private func restoreCommand(kind: String, sessionID: String) -> String {
        [AgentRestoreLaunch.cliStartupExecutableToken, "restore", kind, sessionID]
            .joined(separator: " ")
    }

    /// Creates and validates the explicitly bounded rendered-command result.
    private func compatibilityPlan(
        request: VaultResumeLaunchRequest,
        reason: VaultResumeLaunchPlan.LegacyFallbackReason
    ) -> VaultResumeLaunchPlan? {
        guard let command = request.legacyCommand,
              !command.isEmpty,
              command.unicodeScalars.allSatisfy(isSafeCompatibilityScalar) else {
            return nil
        }
        let plan = VaultResumeLaunchPlan(
            strategy: .legacyCommand,
            posixCommand: command,
            workingDirectory: effectiveWorkingDirectory(for: request),
            structuredSnapshot: nil,
            legacyFallbackReason: reason
        )
        let maximumBytes = VaultResumeLaunchPlan.maximumLegacyResumeInputBytes
        guard plan.startupInput(for: .posix).utf8.count <= maximumBytes,
              plan.startupInput(for: .nushell).utf8.count <= maximumBytes else {
            return nil
        }
        return plan
    }

    /// Applies the registration cwd policy at the package boundary.
    private func effectiveWorkingDirectory(
        for request: VaultResumeLaunchRequest
    ) -> String? {
        guard case let .registered(registration, _) = request.profile,
              registration.workingDirectoryPolicy == .ignore else {
            return request.workingDirectory
        }
        return nil
    }

    /// Converts captured Codex approval and sandbox policy values to CLI flags.
    ///
    /// - Parameters:
    ///   - approvalPolicy: Captured Codex approval policy.
    ///   - sandboxMode: Captured Codex sandbox mode.
    /// - Returns: Sanitized flags accepted by the Codex CLI.
    public func codexApprovalSandboxArgumentTokens(
        approvalPolicy: String?,
        sandboxMode: String?
    ) -> [String] {
        let approvalPolicy = nonEmpty(approvalPolicy).map { policy in
            policy == "on-failure" ? "on-request" : policy
        }
        let sandboxMode = nonEmpty(sandboxMode)
        if approvalPolicy == "never", sandboxMode == "disabled" {
            return ["--dangerously-bypass-approvals-and-sandbox"]
        }
        var arguments: [String] = []
        if let approvalPolicy,
           acceptedCodexApprovalPolicies.contains(approvalPolicy) {
            arguments.append(contentsOf: ["-a", approvalPolicy])
        }
        let allowedModes: Set<String> = ["read-only", "workspace-write", "danger-full-access"]
        if let sandboxMode, allowedModes.contains(sandboxMode) {
            arguments.append(contentsOf: ["-s", sandboxMode])
        }
        return arguments
    }

    /// Trims an optional captured value and treats blank text as absent.
    private func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        return value
    }

    /// Normalizes an optional selector component.
    private func normalized(_ value: String?) -> String? {
        nonEmpty(value)
    }

    /// Rejects controls that could alter a typed compatibility command.
    private func isSafeCompatibilityScalar(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value >= 0x20 && scalar.value != 0x7F && !(0x80...0x9F).contains(scalar.value)
    }
}

private extension VaultResumeLaunchRequest.AgentProfile {
    var isRegistered: Bool {
        if case .registered = self { return true }
        return false
    }
}
