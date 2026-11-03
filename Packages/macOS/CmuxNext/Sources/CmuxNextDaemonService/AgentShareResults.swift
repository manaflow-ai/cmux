import CmuxNextActions
import CmuxNextDaemon
import Foundation

/// `--ttl`: seconds, or a number with `s`, `m`, `h` or `d` (`24h`, `90m`). Nil when absent.
enum AgentShareArguments {
    struct BadTTL: Error {}

    static let minimumTTL: UInt64 = 60
    static let maximumTTL: UInt64 = 7 * 24 * 60 * 60

    static func ttl(_ text: String?) throws -> UInt64? {
        guard let text = text?.trimmingCharacters(in: .whitespaces).lowercased(), !text.isEmpty else { return nil }
        let units: [Character: UInt64] = ["s": 1, "m": 60, "h": 3600, "d": 86400]
        let scale = text.last.flatMap { units[$0] }
        guard let number = UInt64(scale == nil ? text : String(text.dropLast())) else { throw BadTTL() }
        let (seconds, overflow) = number.multipliedReportingOverflow(by: scale ?? 1)
        guard !overflow, (minimumTTL...maximumTTL).contains(seconds) else { throw BadTTL() }
        return seconds
    }
}

/// What a share action answers a waiting caller (`action.run` `result`, the CLI's `--json`).
enum AgentShareResults {
    static func created(_ share: AgentSessionShareCreated) -> [String: ActionResultValue] {
        ["share_id": .string(share.shareId), "url": share.url.map(ActionResultValue.string) ?? .null,
         "expires_at": .int(Int(clamping: share.expiresAt)), "uses_left": .int(Int(share.usesLeft)),
         "session": .string(share.session), "surface": .int(Int(clamping: share.surface))]
    }

    static func list(_ list: AgentSessionShareList) -> [String: ActionResultValue] {
        ["shares": .array(list.shares.map { share in
            .object(["share_id": .string(share.shareId), "state": .string(share.state), "session": .string(share.session),
                     "surface": .int(Int(clamping: share.surface)), "created_at": .int(Int(clamping: share.createdAt)),
                     "expires_at": .int(Int(clamping: share.expiresAt)), "expires_in_secs": .int(Int(clamping: share.expiresInSecs)),
                     "uses_left": .int(Int(share.usesLeft)), "room": share.room.map(ActionResultValue.string) ?? .null,
                     "guests": .array(share.guests.map { guest in
                         .object(["guest_id": .string(guest.guestId), "name": .string(guest.name),
                                  "joined_at": .int(Int(clamping: guest.joinedAt)), "state": .string(guest.state)])
                     })])
        })]
    }

    /// Revoke's `{share_id, state}` or kick's `{share_id, guest_id, state}`.
    static func ended(_ reply: JSONValue) -> [String: ActionResultValue] {
        guard case .object(let fields) = reply else { return [:] }
        return fields.mapValues(value)
    }

    static func value(_ json: JSONValue) -> ActionResultValue {
        switch json {
        case .null: .null
        case .bool(let flag): .bool(flag)
        case .number(let number): number.rounded() == number && abs(number) < 9e15 ? .int(Int(number)) : .double(number)
        case .string(let text): .string(text)
        case .array(let items): .array(items.map(value))
        case .object(let fields): .object(fields.mapValues(value))
        }
    }
}
