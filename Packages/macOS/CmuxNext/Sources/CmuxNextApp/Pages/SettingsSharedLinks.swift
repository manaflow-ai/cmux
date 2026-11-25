import CmuxNextDaemon
import CmuxNextDaemonService
import CmuxNextSettings
import Foundation

/// Settings > Privacy > Shared Links (design chat-multiplayer.md 2, "Shared links"): forwards the page's
/// `cmux.settings.shares.list` and `.revoke` to this Mac's daemon (`agent-session-share-list|revoke`,
/// cmux-tui server/agent_session_shares.rs), which owns every share. The list adds each chat's tab
/// title, which only the app knows; the page shapes, sorts and filters the rows
/// (webviews/src/pages/settings/sharedLinks.ts) and Revoke All revokes each share in turn.
@MainActor
enum SettingsSharedLinks {
    /// `agent-session-share-list` answered as is, so the page sees every field the daemon sends.
    private struct ListRequest: DaemonRequest {
        typealias Response = CmuxNextDaemon.JSONValue
        static let command = AgentSessionShareListRequest.command
    }

    /// `{available, shares, titles}` (`available` false: no daemon); `titles`: each surface's chat, named as its tab is (never about:blank).
    static func list(_ host: (any AgentShareHost)?) async throws -> CmuxNextSettings.JSONValue {
        guard let host, let connection = host.shareLocalConnection else { return .object(["available": .bool(false)]) }
        let reply = try await connection.request(ListRequest())
        let shares: CmuxNextDaemon.JSONValue = if case .object(let fields) = reply, let shares = fields["shares"] { shares } else { .array([]) }
        var titles: [String: CmuxNextDaemon.JSONValue] = [:]
        if case .array(let items) = shares {
            for case .object(let share) in items {
                guard case .number(let number)? = share["surface"], number >= 1, number < 9e15 else { continue }
                let surface = UInt64(number)
                if let tab = host.shareChatTab(session: share["session"]?.stringValue, surface: SurfaceID(rawValue: surface)) { titles[String(surface)] = .string(host.shareTitle(of: tab)) }
            }
        }
        let answer: CmuxNextDaemon.JSONValue = .object(["available": .bool(true), "shares": shares, "titles": .object(titles)])
        return try CmuxNextSettings.JSONValue.parse(JSONEncoder().encode(answer))
    }

    /// The share stops working and its guests leave at once (the daemon closes them).
    static func revoke(_ host: (any AgentShareHost)?, shareID: String) async throws -> CmuxNextSettings.JSONValue {
        guard let connection = host?.shareLocalConnection else { throw DaemonError.notConnected }
        let reply = try await connection.request(AgentSessionShareRevokeRequest(shareId: shareID))
        return try CmuxNextSettings.JSONValue.parse(JSONEncoder().encode(reply))
    }
}
