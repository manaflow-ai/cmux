import CmuxHomeCore
import CmuxNextDaemon
import CmuxNextHomeModel
import Foundation

/// A failed cloud proxy reply as the Home sees it (home-cloud-proxy.md
/// section 6): the `HomeRejection` the store acts on, and whether the daemon
/// held no usable lease. The rule is the Rust op `cloud.reply_classify`
/// (cmux-home-rules `cloud/reply.rs`); this reads the error into its JSON.
nonisolated struct CloudReplyError {
    let error: any Error
    /// The daemon holds no usable lease: none (`cloud_signed_out`), or one
    /// that expired (`cloud_session_expired`, possibly one another trusted
    /// local client set).
    let isNoLease: Bool
    /// The daemon's answer as `HomeRejection`.
    let rejection: HomeRejection

    init(_ error: any Error) {
        self.error = error
        do {
            let classified: Classified = try HomeRules.call("cloud.reply_classify", Request(error: Wire(error)))
            isNoLease = classified.isNoLease
            rejection = classified.rejection.home
        } catch {
            assertionFailure("cloud.reply_classify: \(error)")
            isNoLease = false
            rejection = .indeterminate
        }
    }

    private struct Request: Encodable {
        let error: Wire
    }

    private struct Classified: Decodable {
        let rejection: Rejection
        let isNoLease: Bool
    }

    /// `ReplyError`: the error as Rust reads it.
    private enum Wire: Encodable {
        case command(message: String, code: String?, details: JSONValue?, retryable: Bool?)
        case notConnected, missingCapabilities, daemon, other
        case rejection(Rejection)

        init(_ error: any Error) {
            switch error {
            case let rejection as HomeRejection: self = .rejection(Rejection(rejection))
            case let error as DaemonError:
                switch error {
                case .command(_, let message, let code, let details, let retryable):
                    self = .command(message: message, code: code, details: details, retryable: retryable)
                case .notConnected: self = .notConnected
                case .missingCapabilities: self = .missingCapabilities
                default: self = .daemon
                }
            default: self = .other
            }
        }

        private enum CodingKeys: String, CodingKey { case kind, message, code, details, retryable, rejection }

        func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case let .command(message, code, details, retryable):
                try c.encode("command", forKey: .kind)
                try c.encode(message, forKey: .message)
                try c.encodeIfPresent(code, forKey: .code)
                try c.encodeIfPresent(details, forKey: .details)
                try c.encodeIfPresent(retryable, forKey: .retryable)
            case .notConnected: try c.encode("notConnected", forKey: .kind)
            case .missingCapabilities: try c.encode("missingCapabilities", forKey: .kind)
            case .daemon: try c.encode("daemon", forKey: .kind)
            case .other: try c.encode("other", forKey: .kind)
            case let .rejection(rejection):
                try c.encode("rejection", forKey: .kind)
                try c.encode(rejection, forKey: .rejection)
            }
        }
    }

    /// Rust's `Rejection` (`HomeRejection`, tagged by `kind`).
    private struct Rejection: Codable {
        let kind: String
        var reason: String?
        var retryAfter: Double?

        init(_ rejection: HomeRejection) {
            switch rejection {
            case .ownerUnreachable: kind = "ownerUnreachable"
            case .notAuthorized: kind = "notAuthorized"
            case let .invalid(reason): kind = "invalid"; self.reason = reason
            case let .rateLimited(retryAfter): kind = "rateLimited"; self.retryAfter = retryAfter
            case .indeterminate: kind = "indeterminate"
            }
        }

        var home: HomeRejection {
            switch kind {
            case "ownerUnreachable": .ownerUnreachable
            case "notAuthorized": .notAuthorized
            case "invalid": .invalid(reason ?? "")
            case "rateLimited": .rateLimited(retryAfter: retryAfter)
            default: .indeterminate
            }
        }
    }
}
