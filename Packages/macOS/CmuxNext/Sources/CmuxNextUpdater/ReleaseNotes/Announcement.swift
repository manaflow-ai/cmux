public import Foundation

/// One cmux announcement card (R114), from the signed
/// `<feed folder>/notes/announcements.json` (`{"version":1,"items":[...]}`).
/// Text and an optional allow-listed action id only: never a URL or command.
nonisolated public struct Announcement: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var detail: String?
    /// A registry action id; the app drops it unless it is on its allow-list.
    public var action: String?
    /// Inclusive build bounds (numeric compare); nil is open.
    public var minBuild: String?
    public var maxBuild: String?
    /// ISO 8601 dates; nil is open.
    public var startsAt: String?
    public var expiresAt: String?

    public init(id: String, title: String, detail: String? = nil, action: String? = nil, minBuild: String? = nil,
                maxBuild: String? = nil, startsAt: String? = nil, expiresAt: String? = nil) {
        self.id = id
        self.title = title
        self.detail = detail
        self.action = action
        self.minBuild = minBuild
        self.maxBuild = maxBuild
        self.startsAt = startsAt
        self.expiresAt = expiresAt
    }
}

/// Which announcements show (pure).
nonisolated public struct AnnouncementFilter: Sendable {
    public init() {}

    /// At most `limit`, feed order, for this build and time, not dismissed.
    public static func visible(_ all: [Announcement], build: String, now: Date, dismissed: Set<String>, limit: Int = 3) -> [Announcement] {
        []
    }
}
