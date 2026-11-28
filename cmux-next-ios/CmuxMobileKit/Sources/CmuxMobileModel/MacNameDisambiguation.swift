import Foundation
#if os(iOS)
import CmuxMobileLinkFFI
#endif

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
    /// (the same Mac listed twice) count once. The rule is Rust's
    /// (`cmux-mobile-link-ffi/src/mac_name_tags.rs`); where Rust does not link
    /// (the macOS and Linux package builds, which have no phone UI) no Mac is tagged.
    public init(_ macs: [(id: String, name: String)]) {
        #if os(iOS)
        var tags: [String: String] = [:]
        for entry in macNameTags(macs: macs.map { MacNameInput(id: $0.id, name: $0.name) }) {
            tags[entry.id] = entry.tag
        }
        self.tags = tags
        #else
        tags = [:]
        #endif
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
}
