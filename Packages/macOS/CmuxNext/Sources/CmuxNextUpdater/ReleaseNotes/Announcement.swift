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
        let dates = ISO8601DateFormatter()
        func atOrAfter(_ text: String?, _ open: Bool) -> Bool? {
            guard let text else { return open }
            guard let date = dates.date(from: text) else { return nil }
            return now >= date
        }
        let shown = all.filter { item in
            guard !dismissed.contains(item.id) else { return false }
            if let min = item.minBuild, build.compare(min, options: .numeric) == .orderedAscending { return false }
            if let max = item.maxBuild, build.compare(max, options: .numeric) == .orderedDescending { return false }
            guard let started = atOrAfter(item.startsAt, true), started else { return false }
            guard let expired = atOrAfter(item.expiresAt, false), !expired else { return false }
            return true
        }
        return Array(shown.prefix(limit))
    }
}
