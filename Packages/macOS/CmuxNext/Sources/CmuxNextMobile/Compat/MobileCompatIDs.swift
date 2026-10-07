import CmuxNextDaemon
import Foundation

/// Maps durable daemon identities to the uppercase UUIDs shipped iOS builds
/// require for `workspace_id` and `surface_id` (the old host rejected
/// anything else, and the phone compares them case-insensitively).
enum MobileCompatIDs {
    /// Workspace key (lowercase canonical UUID) to the phone's id.
    static func workspaceID(_ key: WorkspaceKey) -> String { key.rawValue.uppercased() }

    /// Phone workspace id back to the daemon key.
    static func workspaceKey(_ phoneID: String) -> WorkspaceKey? {
        guard let uuid = UUID(uuidString: phoneID) else { return nil }
        return WorkspaceKey(rawValue: uuid.uuidString.lowercased())
    }

    /// Terminal id (32 hex) to a UUID-shaped surface id. The terminal id,
    /// not the tab, is the durable identity: it survives moves between panes.
    static func surfaceID(_ terminal: TerminalID) -> String? { uuidString(fromHex: terminal.rawValue) }

    /// A group id to a stable UUID: `grp_<32 hex>` maps directly, anything
    /// else through a name-based digest.
    static func groupID(_ group: WorkspaceGroupID) -> String {
        let raw = group.rawValue
        let hex = raw.hasPrefix("grp_") ? String(raw.dropFirst(4)) : raw
        return uuidString(fromHex: hex) ?? nameBasedUUID(raw)
    }

    static func uuidString(fromHex hex: String) -> String? {
        let digits = hex.lowercased().filter(\.isHexDigit)
        guard digits.count == 32, digits.count == hex.count else { return nil }
        let chars = Array(digits.uppercased())
        let parts = [0..<8, 8..<12, 12..<16, 16..<20, 20..<32].map { String(chars[$0]) }
        return parts.joined(separator: "-")
    }

    /// FNV-1a over the bytes, spread into 128 bits. Stable across launches;
    /// not a security boundary (the id only names a sidebar group).
    static func nameBasedUUID(_ name: String) -> String {
        var high: UInt64 = 0xcbf29ce484222325
        var low: UInt64 = 0x84222325cbf29ce4
        for byte in name.utf8 {
            high = (high ^ UInt64(byte)) &* 0x100000001b3
            low = (low ^ UInt64(byte)) &* 0x100000001b3 &+ high
        }
        return uuidString(fromHex: String(format: "%016llx%016llx", high, low)) ?? UUID().uuidString
    }
}
