import Foundation

/// Tells apart Macs that share a name ("Aziz's MacBook Pro" twice). Only
/// Macs whose name collides with another in the same list get a tag; a
/// unique name reads as before.
///
/// The tag is the end of the Mac's device id ("3F2A"), the one stable
/// identifier every list has (the team's Macs, presence frames and
/// `GET /v1/me/devices`), so the same Mac carries the same tag in Settings,
/// the Workspaces filter and the remove confirmation. A tag is at least
/// four characters, and longer only when two colliding ids end alike.
public struct MacNameDisambiguation: Sendable, Equatable {
    /// Tag by device id, for Macs whose name collides.
    public let tags: [String: String]

    /// One entry per Mac: its device id and display name. Duplicate ids
    /// (the same Mac listed twice) count once.
    public init(_ macs: [(id: String, name: String)]) {
        var seen = Set<String>()
        let unique = macs.filter { seen.insert($0.id).inserted }
        let groups = Dictionary(grouping: unique, by: { Self.key($0.name) })
        var tags: [String: String] = [:]
        for group in groups.values where group.count > 1 {
            let ids = group.map(\.id)
            for (id, tag) in zip(ids, Self.suffixes(ids)) { tags[id] = tag }
        }
        self.tags = tags
    }

    public init(_ macs: [MacDevice]) {
        self.init(macs.map { (id: $0.id, name: $0.name) })
    }

    /// The Mac's tag ("3F2A") when its name collides; nil otherwise.
    public func tag(for id: String) -> String? { tags[id] }

    /// The account's Macs: every team's, so a Mac carries the same tag on
    /// every surface (Workspaces, Settings → Devices), whichever team it is in.
    /// Both surfaces tag over exactly this set (`scope`); a Mac only the
    /// device service lists does not change anyone's tag.
    public init(account teams: [Team]) {
        self.init(Self.scope(teams))
    }

    /// The Macs that decide which names need a tag: every team's Macs.
    public static func scope(_ teams: [Team]) -> [MacDevice] {
        teams.flatMap(\.macs)
    }

    /// "Aziz's MacBook Pro 3F2A" for a colliding name, else the name: the
    /// text form of the name plus its tag capsule (`MacNameTag`), the one
    /// spelling every alert, menu, subtitle and accessibility value uses.
    public func displayName(id: String, name: String) -> String {
        guard let tag = tags[id] else { return name }
        return "\(name) \(tag)"
    }

    public func displayName(_ mac: MacDevice) -> String { displayName(id: mac.id, name: mac.name) }

    /// "Added Oct 13" for a Mac whose name collides and whose added date is
    /// known; nil otherwise (the tag itself goes next to the name).
    public func added(for id: String, addedAt: Date?) -> String? {
        guard tags[id] != nil, let addedAt else { return nil }
        return "Added \(addedAt.formatted(.dateTime.month(.abbreviated).day()))"
    }

    /// Names that differ only by case or surrounding spaces read the same.
    static func key(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// The shortest id endings (at least four characters, alphanumerics
    /// only, uppercased) that differ across `ids`; an id too short for
    /// that is used whole.
    static func suffixes(_ ids: [String]) -> [String] {
        let cleaned = ids.map { id in
            let chars = id.uppercased().filter { $0.isLetter || $0.isNumber }
            return chars.isEmpty ? id.uppercased() : chars
        }
        let longest = cleaned.map(\.count).max() ?? 0
        var length = 4
        while length < longest {
            let tags = cleaned.map { String($0.suffix(length)) }
            if Set(tags).count == tags.count { return tags }
            length += 1
        }
        return cleaned.map { String($0.suffix(max(length, 4))) }
    }
}
