public import CmuxNextDaemon
import Foundation

/// Why the Chief Settings panel could not read or set the engine, as the
/// panel says it.
public nonisolated enum HomeChiefEngineError: Error, Equatable, Sendable {
    case unreachable
    /// This Mac's Chief (owner daemon or brain host) is not running.
    case localUnreachable
    /// This Mac's brain was not running and has just been started.
    case localStarting
    case forbidden
    case notConfigured
    case unsupported
    /// Agents are off in this build session (`agent_launch_disabled`).
    case agentsDisabled
    case refused(reason: String, message: String)
    /// A hosted cloud Chief: the Cloud service could not be reached (offline, or the Chief list is not read yet).
    case cloudUnreachable
    /// A hosted cloud Chief: no account is signed in, or its sign-in expired.
    case signedOut
    /// A hosted cloud Chief: this Cloud service runs no Chief brains.
    case cloudUnavailable
    /// A hosted cloud Chief's turn: the Cloud service has no stop for it yet.
    case cloudStopUnsupported
    case other(String)

    public init(_ error: ChiefControlError) {
        switch error {
        case .unreachable: self = .unreachable
        case .forbidden: self = .forbidden
        case .notConfigured: self = .notConfigured
        case .unsupported: self = .unsupported
        // cx-tgf4h: the daemon's typed refusal while agents are off.
        case .refused(let reason, _) where reason == "agent_launch_disabled": self = .agentsDisabled
        case .refused(let reason, let message): self = .refused(reason: reason, message: message)
        case .other(let text): self = .other(text)
        }
    }

    /// The error as the person reads it (the settings card, a refused Stop).
    public var text: String {
        switch self {
        case .unreachable: HomeEngineStrings.errorUnreachable
        case .localUnreachable: HomeEngineStrings.errorLocalUnreachable
        case .localStarting: HomeEngineStrings.errorLocalStarting
        case .forbidden: HomeEngineStrings.errorForbidden
        case .notConfigured: HomeEngineStrings.errorNotConfigured
        case .unsupported: HomeEngineStrings.errorUnsupported
        case .agentsDisabled: HomeStrings.chiefAgentsDisabled
        case .cloudUnreachable: HomeEngineStrings.errorCloudUnreachable
        case .signedOut: HomeEngineStrings.errorSignedOut
        case .cloudUnavailable: HomeEngineStrings.errorCloudUnavailable
        case .cloudStopUnsupported: HomeEngineStrings.errorCloudStopUnsupported
        case .refused(_, let message), .other(let message): String(format: HomeEngineStrings.errorRefusedFormat, message)
        }
    }
}
