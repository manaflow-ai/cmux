import Foundation

/// The strongest evidence available for associating a captured launch with an
/// agent hook. This is intentionally separate from the persisted launch-record
/// source so replay policy cannot be inferred from loosely coupled strings.
public enum AgentLaunchCaptureEvidence: Sendable, Equatable {
    case exactEnvironmentLauncher
    case wrapperEnvironmentLauncher
    case nativeProcess
    case unavailable
}

/// The only replay states a hook capture can produce.
public enum AgentLaunchReplayPlan: Sendable, Equatable {
    case captured(arguments: [String], evidence: AgentLaunchCaptureEvidence)
    case canonical
    case rejected
    case unavailable
}

/// Converts launch evidence and sanitizer output into one durable replay plan.
///
/// Capture validation proves the original invocation belongs to the agent.
/// Sanitization separately proves which arguments are safe to replay. If
/// sanitization removes an interpreter-hosted agent's script identity, the
/// original executable must not be replayed; trusted native or exact-launcher
/// evidence instead selects the provider's canonical resume command.
public struct AgentLaunchReplayPlanner: Sendable, Equatable {
    public init() {}

    public func plan(
        kind: String,
        launcher: String?,
        executablePath: String?,
        capturedArguments: [String]?,
        sanitizedArguments: [String]?,
        evidence: AgentLaunchCaptureEvidence,
        hasSelectedEnvironment: Bool
    ) -> AgentLaunchReplayPlan {
        guard let capturedArguments, !capturedArguments.isEmpty else {
            if evidence == .exactEnvironmentLauncher
                || hasSelectedEnvironment
                || normalized(kind) == "codex" {
                return .canonical
            }
            return .unavailable
        }

        let originalDescribesKind = AgentLaunchCaptureTrust.capturedArgumentsDescribeKind(
            launcher: launcher,
            executablePath: executablePath,
            arguments: capturedArguments,
            kind: kind
        )
        guard originalDescribesKind else {
            return evidence == .exactEnvironmentLauncher ? .canonical : .unavailable
        }

        guard let sanitizedArguments else {
            return .rejected
        }
        if AgentLaunchCaptureTrust.capturedArgumentsDescribeKind(
            launcher: launcher,
            executablePath: executablePath,
            arguments: sanitizedArguments,
            kind: kind
        ) {
            return .captured(arguments: sanitizedArguments, evidence: evidence)
        }

        switch evidence {
        case .exactEnvironmentLauncher, .nativeProcess:
            return .canonical
        case .wrapperEnvironmentLauncher, .unavailable:
            return .unavailable
        }
    }

    private func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
