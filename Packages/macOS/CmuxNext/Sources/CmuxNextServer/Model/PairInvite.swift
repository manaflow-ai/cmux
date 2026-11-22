public import Foundation

/// One minted invite (`server.pair.invite`): the code the new machine types, when it stops working,
/// and the secret that opens its watch socket. The secret never shows and never leaves the app
/// except as the socket's `watch.<secret>` subprotocol.
public nonisolated struct PairInvite: Sendable, Equatable {
    /// Ten Crockford base32 symbols without the dash.
    public let code: String
    public let expiresAt: Date
    public let watchSecret: String

    public init(code: String, expiresAt: Date, watchSecret: String) {
        self.code = PairingCode.Invite.normalize(code)
        self.expiresAt = expiresAt
        self.watchSecret = watchSecret
    }

    public var displayCode: String { PairingCode.Invite.display(code) }
    /// `cmux pair ABCDE-12345`.
    public var line: String { PairingCode.Invite.line(code) }
    /// The install line, then the invite, for a machine without cmux.
    public var installLine: String { PairingCode.Invite.installLine(code) }
    public var qrPayload: String { PairingCode.Invite.payload(code) }

    /// The `value` of a `server.pair.invite` reply (`{invite, display, expires_at, watch_secret}`);
    /// nil when a field is missing, the code is not a complete invite code, or the secret is empty.
    public static func decode(_ value: Any?) -> PairInvite? {
        guard let value = value as? [String: Any],
              let code = value["invite"] as? String, PairingCode.Invite.isComplete(code),
              let secret = value["watch_secret"] as? String, !secret.isEmpty,
              let expires = PairInviteFrame.date(value["expires_at"]) else { return nil }
        return PairInvite(code: code, expiresAt: expires, watchSecret: secret)
    }
}

/// What the invite's watch socket says (`GET /v1/pair/invite/wait`, subprotocols
/// `cmux.pair-invite.v1, watch.<secret>`). Pushed by the Worker, never polled.
public nonisolated enum PairInviteFrame: Sendable, Equatable {
    /// No machine has used the code yet.
    case pending(expiresAt: Date?)
    /// A machine redeemed the code: its pending server pairing has the 8-symbol `code`, which
    /// `server.pair.preview` reads (also replayed on connect when it already arrived).
    case arrived(code: String)
    /// The approve completed: the machine is enrolled as `host`.
    case paired(host: String)
    /// A second machine used the code (or a new invite replaced this one): nothing pairs with it.
    case voided(reason: String)
    /// The code's ten minutes ran out (close 4408).
    case expired
    /// The socket closed for any other reason (network, the Worker went away).
    case lost

    /// The socket's close code at expiry.
    public static let expiryCloseCode = 4408
    /// The two subprotocols the watch socket is opened with.
    public static func protocols(secret: String) -> [String] { ["cmux.pair-invite.v1", "watch.\(secret)"] }

    /// One text frame; nil for an unknown or malformed one (it is skipped).
    public static func decode(_ data: Data) -> PairInviteFrame? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        switch object["t"] as? String {
        case "pending":
            return .pending(expiresAt: date(object["expires_at"]))
        case "arrived":
            guard let code = object["code"] as? String, PairingCode.isComplete(code) else { return nil }
            return .arrived(code: PairingCode.normalize(code))
        case "paired":
            return .paired(host: object["host"] as? String ?? "")
        case "voided":
            return .voided(reason: object["reason"] as? String ?? "")
        default:
            return nil
        }
    }

    /// The Worker's times are epoch milliseconds (`Date.now()`); an RFC 3339 string reads too.
    static func date(_ value: Any?) -> Date? {
        if let number = value as? NSNumber, !(value is Bool) {
            return Date(timeIntervalSince1970: number.doubleValue / 1000)
        }
        guard let text = value as? String else { return nil }
        let full = ISO8601DateFormatter()
        full.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return full.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }
}

/// Why no invite could be made. The words come from the app, never a raw error dump.
public nonisolated enum PairInviteFailure: Error, Equatable, Sendable {
    /// The app holds no cmux account to mint with.
    case signedOut
    /// The Worker refused or could not be reached; `text` is the app's own sentence for it.
    case refused(String)
}
