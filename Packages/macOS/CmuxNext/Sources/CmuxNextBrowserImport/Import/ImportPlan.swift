import Foundation

/// What to import: per source profile, the kinds the user picked.
public struct ImportPlan: Sendable, Equatable {
    public struct Item: Sendable, Equatable {
        public var profile: BrowserSourceProfile
        public var kinds: Set<ImportDataKind>

        public init(profile: BrowserSourceProfile, kinds: Set<ImportDataKind>) {
            self.profile = profile
            self.kinds = kinds.filter { profile.availability(of: $0).isImportable }
        }
    }

    public var items: [Item]
    /// History pages kept per profile, newest first.
    public var historyLimit: Int
    /// Set: every source goes into this one cmux profile instead of a new
    /// profile per source ("merge into one").
    public var mergeTarget: String?

    public static let defaultHistoryLimit = 5_000
    /// The id of cmux's default browser profile.
    public static let defaultProfileID = "default"

    public init(items: [Item], historyLimit: Int = ImportPlan.defaultHistoryLimit, mergeTarget: String? = nil) {
        self.items = items.filter { !$0.kinds.isEmpty }
        self.historyLimit = historyLimit
        self.mergeTarget = mergeTarget
    }
}

/// Where an import stands, for the progress row.
public struct ImportProgress: Sendable, Equatable {
    public var profileIndex: Int
    public var profileCount: Int
    public var profile: BrowserSourceProfile
    /// The kind being read now; nil while the profile is being saved.
    public var kind: ImportDataKind?
    /// 0...1 over the whole plan.
    public var fraction: Double
    public var counts: ImportCounts

    public init(profileIndex: Int, profileCount: Int, profile: BrowserSourceProfile, kind: ImportDataKind?, fraction: Double, counts: ImportCounts) {
        self.profileIndex = profileIndex
        self.profileCount = profileCount
        self.profile = profile
        self.kind = kind
        self.fraction = fraction
        self.counts = counts
    }
}

/// Items read so far (or imported, in a summary). Cookies count the ones
/// the target profile's store accepted.
public struct ImportCounts: Sendable, Equatable, Codable {
    public var bookmarks = 0
    public var history = 0
    public var openTabs = 0
    public var extensions = 0
    public var cookies = 0
    /// Passwords newly saved (never the values).
    public var passwords = 0

    public init(bookmarks: Int = 0, history: Int = 0, openTabs: Int = 0, extensions: Int = 0, cookies: Int = 0, passwords: Int = 0) {
        self.bookmarks = bookmarks
        self.history = history
        self.openTabs = openTabs
        self.extensions = extensions
        self.cookies = cookies
        self.passwords = passwords
    }

    public var total: Int { bookmarks + history + openTabs + extensions + cookies + passwords }

    public static func + (lhs: ImportCounts, rhs: ImportCounts) -> ImportCounts {
        ImportCounts(bookmarks: lhs.bookmarks + rhs.bookmarks, history: lhs.history + rhs.history, openTabs: lhs.openTabs + rhs.openTabs,
                     extensions: lhs.extensions + rhs.extensions, cookies: lhs.cookies + rhs.cookies, passwords: lhs.passwords + rhs.passwords)
    }

    public static func - (lhs: ImportCounts, rhs: ImportCounts) -> ImportCounts {
        ImportCounts(bookmarks: lhs.bookmarks - rhs.bookmarks, history: lhs.history - rhs.history, openTabs: lhs.openTabs - rhs.openTabs,
                     extensions: lhs.extensions - rhs.extensions, cookies: lhs.cookies - rhs.cookies, passwords: lhs.passwords - rhs.passwords)
    }
}
