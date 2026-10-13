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
        guard let data = String(line).data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String else { return nil }
        let text = { (key: String) -> String? in object[key] as? String }
        switch type {
        case "connecting":
            self = .connecting
        case "online":
            guard let device = text("device_id"), let team = text("team_id") else { return nil }
            self = .online(deviceID: device, teamID: team)
        case "waiting":
            self = .waiting(reason: text("reason") ?? "", retryInSeconds: (object["retry_in_seconds"] as? NSNumber)?.intValue ?? 0)
        case "need_token":
            self = .needToken
        case "need_acpmux":
            self = .needAcpmux
        case "phone_up":
            guard let session = text("session_id"), let phone = text("phone_device_id") else { return nil }
            self = .phoneUp(CnxPhoneLink(sessionID: session, phoneDeviceID: phone,
                                         transport: text("transport") ?? "", path: text("path") ?? ""))
        case "phone_path":
            guard let session = text("session_id"), let path = text("path") else { return nil }
            self = .phonePath(sessionID: session, path: path)
        case "phone_down":
            guard let session = text("session_id") else { return nil }
            self = .phoneDown(sessionID: session, reason: text("reason") ?? "")
        default:
            return nil
        }
    }
}
