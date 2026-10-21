public import CmuxNextIcons
public import Foundation

/// A part of cmux the App Store's Features tab turns on and off (Leo, 2026-10-20: "we already
/// ship the code", so finished features are listed here instead of behind Labs). Each one is
/// one existing cmux-next.json key, never a parallel config: Get writes ``Switch/onValue`` with
/// the person's authority, Remove puts the key back to off, and the settings file watcher
/// applies the change to every window at once. Unfinished surfaces stay behind
/// `labs.previewFeatures`.
public nonisolated struct AppFeature: Sendable, Hashable, Identifiable {
    /// The value of the key that means on.
    public enum Switch: Sendable, Hashable {
        /// An on/off key: on is `true`.
        case toggle
        /// A choice key: on is this choice. Remove clears the key, so its default applies.
        case choice(String)
        /// A sidebar item (the `SidebarBuiltIn` name; its `setting` is `sidebar.layout`, where the
        /// item lives): on while the sidebar shows it. Get adds it, Remove takes every copy out,
        /// both as the person's edit (Undo takes it back).
        case sidebarItem(String)
    }

    public enum Category: String, Sendable, Hashable, CaseIterable {
        case backgrounds
        case chief
        case newTab
        case sidebar
        case media
        case browser
    }

    /// What the card shows above its name.
    public enum Preview: Sendable, Hashable {
        case icon(IconName)
        /// One of the bundled paintings' thumbnails (`BackdropArt.thumbnailURL`).
        case painting
    }

    /// Stable id (`appStore.feature.<id>` in accessibility and tests).
    public var id: String
    /// The dotted cmux-next.json key.
    public var setting: String
    public var on: Switch
    public var category: Category
    public var preview: Preview
    public var name: String
    /// One line: what turning it on adds.
    public var summary: String
    /// Search words beyond the name and summary.
    public var keywords: [String]
    /// The key whose rows Settings shows from the card's Settings… link (the feature's own
    /// options, as the Chief Pet card opens Settings > Chief Pet); nil: the card has no link.
    public var settingsLink: String?

    public init(id: String, setting: String, on: Switch, category: Category, preview: Preview,
                name: String, summary: String, keywords: [String] = [], settingsLink: String? = nil) {
        self.id = id
        self.setting = setting
        self.on = on
        self.category = category
        self.preview = preview
        self.name = name
        self.summary = summary
        self.keywords = keywords
        self.settingsLink = settingsLink
    }

    /// The sidebar item a `.sidebarItem` feature shows; nil for a settings key.
    public var sidebarItem: String? {
        if case .sidebarItem(let name) = on { return name }
        return nil
    }

    /// The key as a path (`["home", "chiefPetEnabled"]`).
    public var path: [String] { setting.split(separator: ".").map(String.init) }

    /// Matches a store search: name, summary, key, category and keywords.
    public func matches(_ query: String) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return true }
        let haystack = ([name, summary, setting, AppsStrings.featureCategory(category)] + keywords).joined(separator: " ").lowercased()
        return needle.split(separator: " ").allSatisfy { haystack.contains($0) }
    }
}

/// The settings side of the Features tab, given by the App (`CmuxNextApps` does not read the
/// settings file itself). Reads are observable: a view body that asks ``isOn(_:)`` draws again
/// when the file changes, whoever changed it (Settings, `cmux settings set`, an agent).
@MainActor
public protocol AppFeatureSettings: AnyObject {
    /// Whether the settings schema knows `feature`'s key; a feature whose key has not landed
    /// yet is not listed.
    func isAvailable(_ feature: AppFeature) -> Bool
    /// Whether the value in effect is `feature`'s on value.
    func isOn(_ feature: AppFeature) -> Bool
    /// Whether an MDM profile or the team policy manages the key (the button is disabled).
    func isManaged(_ feature: AppFeature) -> Bool
    /// Writes the key with the person's authority (a button press on this page).
    func set(_ feature: AppFeature, on: Bool) async throws
    /// Whether the card links to Settings: the feature names rows and Settings can show them.
    func hasSettings(_ feature: AppFeature) -> Bool
    /// Opens Settings on `feature`'s ``AppFeature/settingsLink`` rows.
    func openSettings(_ feature: AppFeature)
}
