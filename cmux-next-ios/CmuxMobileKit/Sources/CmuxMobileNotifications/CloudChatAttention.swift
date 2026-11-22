import Foundation

/// A Cloud attention push names a chat, never a local Mac session. The app
/// resolves these identifiers against the signed-in account before opening it.
/// Tapping it cannot approve a permission or send a message.
public struct CloudChatAttention: Equatable, Hashable, Sendable {
    public enum Kind: String, Hashable, Sendable { case question, permission, done }

    public let kind: Kind
    public let eventID: String
    public let machineID: String
    public let sessionID: String
    public let teamID: String

    public init?(userInfo: [AnyHashable: Any]) {
        guard let cmux = userInfo["cmux"] as? [String: Any],
              let cloud = cmux["cloud"] as? [String: Any],
              let kind = (cloud["kind"] as? String).flatMap(Kind.init(rawValue:)),
              let event = cloud["event_id"] as? String, !event.isEmpty,
              let machine = cloud["machine_id"] as? String, !machine.isEmpty,
              let session = cloud["session_id"] as? String, !session.isEmpty,
              let team = cloud["team_id"] as? String, !team.isEmpty else { return nil }
        self.kind = kind
        eventID = event
        machineID = machine
        sessionID = session
        teamID = team
    }
}
