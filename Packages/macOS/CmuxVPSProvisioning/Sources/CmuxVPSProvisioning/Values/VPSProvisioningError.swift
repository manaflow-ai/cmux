internal import Foundation

/// Errors surfaced by VPS provisioning, each carrying enough context for an
/// actionable CLI message.
public enum VPSProvisioningError: Error, Equatable, Sendable {
    /// SSH to the host failed (auth, network, or non-zero exit while probing).
    case sshFailed(detail: String)
    /// The probe ran but its output could not be parsed.
    case probeParseFailed(detail: String)
    /// The remote platform has no published cmuxd-remote build.
    case unsupportedPlatform(unameOS: String, unameArch: String)
    /// No verified daemon binary could be acquired for the platform.
    case artifactUnavailable(detail: String)
    /// The uploaded binary's remote checksum did not match the verified local
    /// artifact.
    case checksumMismatch(expected: String, actual: String)
    /// A remote command failed while applying the plan.
    case remoteCommandFailed(step: String, detail: String)
    /// The post-install health check failed end to end.
    case healthCheckFailed(detail: String)
    /// The daemon reports live PTY sessions and the operation would destroy
    /// them; pass `--force` to proceed anyway.
    case liveSessionsPresent(count: Int)
    /// The host is not registered with `cmux vps add`.
    case hostNotRegistered(destination: String)
    /// The registry file could not be read or written.
    case registryFailure(detail: String)

    /// One-line human-readable description used by CLI error paths.
    public var detailDescription: String {
        switch self {
        case .sshFailed(let detail):
            return "ssh failed: \(detail)"
        case .probeParseFailed(let detail):
            return "host probe returned unexpected output: \(detail)"
        case .unsupportedPlatform(let unameOS, let unameArch):
            return "unsupported platform \(unameOS)/\(unameArch); cmuxd-remote ships for linux/darwin on amd64/arm64"
        case .artifactUnavailable(let detail):
            return "no verified cmuxd-remote binary available: \(detail)"
        case .checksumMismatch(let expected, let actual):
            return "uploaded binary checksum mismatch (expected \(expected), got \(actual))"
        case .remoteCommandFailed(let step, let detail):
            return "\(step) failed: \(detail)"
        case .healthCheckFailed(let detail):
            return "daemon health check failed: \(detail)"
        case .liveSessionsPresent(let count):
            return "refusing: \(count) live PTY session(s) would be destroyed; re-run with --force to proceed"
        case .hostNotRegistered(let destination):
            return "\(destination) is not a registered VPS host; run `cmux vps add \(destination)` first"
        case .registryFailure(let detail):
            return "VPS registry error: \(detail)"
        }
    }
}
