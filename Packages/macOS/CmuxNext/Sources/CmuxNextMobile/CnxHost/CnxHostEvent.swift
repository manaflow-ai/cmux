import Foundation

/// One status line `cnx-hostd` writes on stdout when the app supervises it
/// (`CNX_CONTROL=stdio`, cnx-ios/rust/crates/cnx-hostd/src/control.rs).
public enum CnxHostEvent: Sendable, Equatable {
    /// Registering the Mac and opening the signaling socket.
    case connecting
    /// Registered and holding the signaling socket: phones can dial.
    case online(deviceID: String, teamID: String)
    /// The last attempt failed or the socket closed; hostd retries after the delay.
    case waiting(reason: String, retryInSeconds: Int)
    /// The access token is missing, about to expire, or was refused.
    case needToken
    /// acpmux is unknown or refused a connection (it restarted elsewhere).
    case needAcpmux
    /// A phone's link is up.
    case phoneUp(CnxPhoneLink)
    /// A phone's link moved to another path (`direct`, `relay`, `turn`).
    case phonePath(sessionID: String, path: String)
    /// A phone's link ended.
    case phoneDown(sessionID: String, reason: String)

    /// Parses one stdout line; nil for anything that is not a known event.
    public init?(line: some StringProtocol) {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let wire = try? decoder.decode(Wire.self, from: Data(String(line).utf8)) else { return nil }
        switch wire.type {
        case "connecting":
            self = .connecting
        case "online":
            guard let device = wire.deviceId, let team = wire.teamId else { return nil }
            self = .online(deviceID: device, teamID: team)
        case "waiting":
            self = .waiting(reason: wire.reason ?? "", retryInSeconds: wire.retryInSeconds ?? 0)
        case "need_token":
            self = .needToken
        case "need_acpmux":
            self = .needAcpmux
        case "phone_up":
            guard let session = wire.sessionId, let phone = wire.phoneDeviceId else { return nil }
            self = .phoneUp(CnxPhoneLink(sessionID: session, phoneDeviceID: phone,
                                         transport: wire.transport ?? "", path: wire.path ?? ""))
        case "phone_path":
            guard let session = wire.sessionId, let path = wire.path else { return nil }
            self = .phonePath(sessionID: session, path: path)
        case "phone_down":
            guard let session = wire.sessionId else { return nil }
            self = .phoneDown(sessionID: session, reason: wire.reason ?? "")
        default:
            return nil
        }
    }

    /// The line's fields (`control.rs` `Event`; snake case on the wire).
    private struct Wire: Decodable {
        var type: String
        var deviceId: String?
        var teamId: String?
        var reason: String?
        var retryInSeconds: Int?
        var sessionId: String?
        var phoneDeviceId: String?
        var transport: String?
        var path: String?
    }
}
