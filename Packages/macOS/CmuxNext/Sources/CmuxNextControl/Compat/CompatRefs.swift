import CryptoKit
import Foundation
import Synchronization

/// Old-app UUIDs for cmux-tui objects, derived without state so they are
/// the same in every app process and across daemon restarts:
/// - workspace: its durable key (already a UUID);
/// - pane, tab (surface), screen: the 32 hex digits of `pane_…`/`tab_…`;
/// - anything else: an MD5 of its stable string id.
/// Output is uppercase like the old app's `UUID().uuidString`; input
/// matching ignores case.
enum CompatUUID {
    static func from(resourceID: String) -> String {
        if let separator = resourceID.lastIndex(of: "_") {
            let hex = resourceID[resourceID.index(after: separator)...]
            if let uuid = fromHex(hex) { return uuid }
        }
        if let uuid = UUID(uuidString: resourceID) { return uuid.uuidString }
        return hashed(resourceID)
    }

    static func fromHex(_ hex: Substring) -> String? {
        guard hex.count == 32, hex.allSatisfy(\.isHexDigit) else { return nil }
        let h = Array(hex.uppercased())
        let parts = [h[0..<8], h[8..<12], h[12..<16], h[16..<20], h[20..<32]].map { String($0) }
        return parts.joined(separator: "-")
    }

    static func hashed(_ text: String) -> String {
        var bytes = Array(Insecure.MD5.hash(data: Data(text.utf8)))
        bytes[6] = (bytes[6] & 0x0F) | 0x30
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        let uuid = UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                               bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
        return uuid.uuidString
    }

    /// Canonical uppercase form of a UUID string, or nil.
    static func canonical(_ text: String) -> String? {
        UUID(uuidString: text.trimmingCharacters(in: .whitespaces))?.uuidString
    }
}

/// Short refs (`workspace:3`, `pane:7`, `surface:12`, `window:1`) the old
/// CLI prints by default. Numbers are assigned per session and kind on first
/// sight and never reused for the life of the app process, like the old
/// app's handle registry, so a ref a script saved keeps naming the same
/// object. Objects of a remote session print qualified
/// (`build-box:workspace:3`, plans/cmux-next/data-model.md 1.3); the home
/// session's refs keep the old unqualified form. Windows are personal and
/// never qualified.
final class CompatRefRegistry: Sendable {
    enum Kind: String, Sendable, CaseIterable {
        case window, workspace, pane, surface
    }

    private struct Key: Hashable {
        var session: String
        var kind: Kind
    }

    private struct Table {
        var numbers: [Key: [String: Int]] = [:]
        var uuids: [Key: [Int: String]] = [:]
        var next: [Key: Int] = [:]
    }

    private let table = Mutex(Table())

    /// `kind:N` for the home session, `<qualifier>:kind:N` for `session`.
    func ref(_ kind: Kind, _ uuid: String, session: CompatWorld.Session? = nil) -> String {
        let local = "\(kind.rawValue):\(number(kind, uuid, session: session?.id))"
        guard let session, !session.isHome, kind != .window else { return local }
        return "\(session.qualifier):\(local)"
    }

    /// The number of `uuid` in `session`'s table (nil: the home session).
    func number(_ kind: Kind, _ uuid: String, session: String? = nil) -> Int {
        let key = Key(session: kind == .window ? "" : session ?? "", kind: kind)
        return table.withLock { table in
            if let number = table.numbers[key]?[uuid] { return number }
            let number = (table.next[key] ?? 0) + 1
            table.next[key] = number
            table.numbers[key, default: [:]][uuid] = number
            table.uuids[key, default: [:]][number] = uuid
            return number
        }
    }

    func uuid(_ kind: Kind, number: Int, session: String? = nil) -> String? {
        let key = Key(session: kind == .window ? "" : session ?? "", kind: kind)
        return table.withLock { $0.uuids[key]?[number] }
    }

    /// Parses `kind:N`. Returns nil for anything else (a qualified ref too).
    static func parse(_ text: String) -> (kind: Kind, number: Int)? {
        let pieces = text.trimmingCharacters(in: .whitespaces).split(separator: ":", omittingEmptySubsequences: false)
        guard pieces.count == 2, let kind = Kind(rawValue: pieces[0].lowercased()), let number = Int(pieces[1]) else { return nil }
        return (kind, number)
    }

    /// Splits a session qualifier off `text`: `build-box:workspace:3` gives
    /// (`build-box`, `workspace:3`), `build-box:tab_9f…` gives (`build-box`,
    /// `tab_9f…`). A leading piece that is a ref kind, a UUID or an index is
    /// no qualifier (`workspace:3`, `handle:7` stay whole), and neither is a
    /// qualifier `isSession` rejects.
    static func splitQualifier(_ text: String, isSession: (String) -> Bool) -> (session: String?, rest: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let colon = trimmed.firstIndex(of: ":") else { return (nil, trimmed) }
        let head = String(trimmed[..<colon])
        let rest = String(trimmed[trimmed.index(after: colon)...])
        guard !head.isEmpty, !rest.isEmpty, Kind(rawValue: head.lowercased()) == nil, head.lowercased() != "tab",
              head.lowercased() != "handle", head.lowercased() != "terminal", Int(head) == nil, isSession(head) else {
            return (nil, trimmed)
        }
        return (head, rest)
    }
}
