public import CmuxNextDaemon
import CmuxNextHomeModel
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

    /// The error as the person reads it (the settings card, a refused Stop). Rust's
    /// `chief_settings.engineError`, given every localized error text.
    public var text: String {
        let fallback: String = switch self {
        case .refused(_, let message), .other(let message): message
        default: ""
        }
        let reply: Wire? = try? HomeRules.call("chief_settings.engineError", Request(error: wire, strings: HomeChiefRuleStrings()))
        return reply?.text ?? fallback
    }

    /// The error as the rules name it (cmux-home-rules `chief_settings::EngineError`).
    var wire: Wire {
        switch self {
        case .unreachable: Wire(kind: "unreachable")
        case .localUnreachable: Wire(kind: "localUnreachable")
        case .localStarting: Wire(kind: "localStarting")
        case .forbidden: Wire(kind: "forbidden")
        case .notConfigured: Wire(kind: "notConfigured")
        case .unsupported: Wire(kind: "unsupported")
        case .agentsDisabled: Wire(kind: "agentsDisabled")
        case .cloudUnreachable: Wire(kind: "cloudUnreachable")
        case .signedOut: Wire(kind: "signedOut")
        case .cloudUnavailable: Wire(kind: "cloudUnavailable")
        case .cloudStopUnsupported: Wire(kind: "cloudStopUnsupported")
        case .refused(let reason, let message): Wire(kind: "refused", reason: reason, message: message)
        case .other(let message): Wire(kind: "other", message: message)
        }
    }

    /// The error an op returned (`hostedConfig`'s `error`).
    init(wire: Wire) {
        switch wire.kind {
        case "unreachable": self = .unreachable
        case "localUnreachable": self = .localUnreachable
        case "localStarting": self = .localStarting
        case "forbidden": self = .forbidden
        case "notConfigured": self = .notConfigured
        case "unsupported": self = .unsupported
        case "agentsDisabled": self = .agentsDisabled
        case "cloudUnreachable": self = .cloudUnreachable
        case "signedOut": self = .signedOut
        case "cloudUnavailable": self = .cloudUnavailable
        case "cloudStopUnsupported": self = .cloudStopUnsupported
        case "refused": self = .refused(reason: wire.reason ?? "", message: wire.message ?? "")
        default: self = .other(wire.message ?? wire.text ?? "")
        }
    }

    nonisolated struct Wire: Codable, Equatable {
        var kind: String
        var reason: String?
        var message: String?
        var text: String?
    }

    private nonisolated struct Request: Encodable {
        var error: Wire
        var strings: HomeChiefRuleStrings
    }
}
