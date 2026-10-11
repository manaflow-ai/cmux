import CmuxNextDaemon
import Foundation

/// Why the Chief Settings panel could not read or set the engine, as the
/// panel says it.
nonisolated enum HomeChiefEngineError: Error, Equatable, Sendable {
    case unreachable
    /// This Mac's Chief (owner daemon or brain host) is not running.
    case localUnreachable
    case forbidden
    case notConfigured
    case unsupported
    case refused(reason: String, message: String)
    case other(String)

    init(_ error: ChiefControlError) {
        switch error {
        case .unreachable: self = .unreachable
        case .forbidden: self = .forbidden
        case .notConfigured: self = .notConfigured
        case .unsupported: self = .unsupported
        case .refused(let reason, let message): self = .refused(reason: reason, message: message)
        case .other(let text): self = .other(text)
        }
    }

    var text: String {
        switch self {
        case .unreachable: HomeEngineStrings.errorUnreachable
        case .localUnreachable: HomeEngineStrings.errorLocalUnreachable
        case .forbidden: HomeEngineStrings.errorForbidden
        case .notConfigured: HomeEngineStrings.errorNotConfigured
        case .unsupported: HomeEngineStrings.errorUnsupported
        case .refused(_, let message), .other(let message): String(format: HomeEngineStrings.errorRefusedFormat, message)
        }
    }
}
