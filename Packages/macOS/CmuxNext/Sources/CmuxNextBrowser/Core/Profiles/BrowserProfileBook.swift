public import Foundation
import CmuxNextDesign

/// Every browser profile of this app install plus the per-workspace defaults
/// the home daemon cannot hold yet (plans/cmux-next/data-model.md section 5).
/// A value type: the App keeps one, edits it on the main actor and saves it
/// with `BrowserProfileBookFile`. The default profile always exists.
public nonisolated struct BrowserProfileBook: Codable, Hashable, Sendable {
    public private(set) var profiles: [BrowserProfileRecord]
    /// Browser profile of a qualified workspace (`<session>|<key>`) when the
    /// home daemon lacks `profiles-v1`; with it, the daemon's
    /// `personal_workspaces.browser_profile_id` is used instead.
    public var workspaceDefaults: [String: String]
    /// Deleted profiles whose engine data is not removed yet (Chromium keeps
    /// a loaded profile's files open until the next launch).
    public private(set) var pendingCleanup: [String]
    /// True once imports made before profiles existed moved into their own
    /// profiles (`ImportedDataStore.retarget`).
    public var importsMigrated: Bool

    public init(defaultName: String = BrowserProfileStrings.defaultName) {
        profiles = [BrowserProfileRecord(id: BrowserProfileRecord.defaultID, name: defaultName, position: 0)]
        workspaceDefaults = [:]
        pendingCleanup = []
        importsMigrated = false
    }

    enum CodingKeys: String, CodingKey {
        case profiles, workspaceDefaults = "workspace_defaults", pendingCleanup = "pending_cleanup", importsMigrated = "imports_migrated"
    }

    /// Tolerates missing keys (an older file) and restores the default
    /// profile if a file lost it.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        let stored = try c.decodeIfPresent([BrowserProfileRecord].self, forKey: .profiles) ?? []
        var seen = Set<String>()
        let valid = stored.filter { BrowserProfileRecord.isValidID($0.id) && seen.insert($0.id).inserted }
        if !valid.isEmpty { profiles = valid.contains(where: \.isDefault) ? valid : profiles + valid }
        workspaceDefaults = try c.decodeIfPresent([String: String].self, forKey: .workspaceDefaults) ?? [:]
        pendingCleanup = try c.decodeIfPresent([String].self, forKey: .pendingCleanup) ?? []
        importsMigrated = try c.decodeIfPresent(Bool.self, forKey: .importsMigrated) ?? false
    }

    /// Profiles in display order, the default one first unless moved.
    public var ordered: [BrowserProfileRecord] { profiles.sorted { ($0.position, $0.id) < ($1.position, $1.id) } }

    public func record(_ id: String) -> BrowserProfileRecord? { profiles.first { $0.id == id } }

    public func contains(_ id: String) -> Bool { record(id) != nil }

    /// The engine store for a tab record's profile id. A deleted profile's
    /// id maps to the default store, so a stray tab never recreates it; a
    /// valid id this book does not know (a tab made on another Mac) keeps
    /// its own store.
    public func engineProfile(for wireID: String?) -> BrowserProfileID {
        .default // stub
    }

    @discardableResult
    public mutating func create(id: String = BrowserProfileRecord.newID(), name: String, color: String?, icon: String?,
                                source: [String: String]? = nil) throws -> BrowserProfileRecord {
        BrowserProfileRecord(id: id, name: name) // stub
    }

    public mutating func rename(_ id: String, to name: String) throws {}
    public mutating func setColor(_ id: String, _ color: String?) throws {}
    public mutating func setIcon(_ id: String, _ icon: String?) throws {}
    public mutating func move(_ id: String, to index: Int) throws {}
    public mutating func delete(_ id: String) throws {}
    public mutating func finishCleanup(_ ids: [String]) {}

    static func validName(_ name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 64 else { throw BrowserProfileBookError.invalidName }
        return trimmed
    }

    static func validColor(_ color: String?) throws -> String? {
        guard let color, !color.isEmpty else { return nil }
        guard GroupColor(rawValue: color) != nil else { throw BrowserProfileBookError.invalidColor }
        return color
    }

    /// An SF Symbol name (ASCII letters, digits, dots) or one grapheme (an emoji).
    static func validIcon(_ icon: String?) throws -> String? {
        guard let icon = icon?.trimmingCharacters(in: .whitespaces), !icon.isEmpty else { return nil }
        let symbol = icon.count <= 64 && icon.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == ".") }
        guard symbol || icon.count == 1 else { throw BrowserProfileBookError.invalidIcon }
        return icon
    }
}
