public import Foundation

/// What a found or staged update says about itself on the update cards
/// (Lawrence 2026-10-10: "we need more details here like changelog stuff"):
/// a short version, the build date, and the first lines of its changelog.
/// The lines come from the appcast item's `<description>` (nightly-next
/// writes "New: …" lines there) or from the build's signed release notes.
/// Codable: What's New persists the staged changelog across the update
/// relaunch (cx-ncc.45).
nonisolated public struct UpdateChangelog: Codable, Equatable, Sendable {
    /// Lines the cards show.
    public static let shownLines = 4

    public var version: String?
    public var date: Date?
    public var lines: [String]

    public init(version: String?, date: Date?, lines: [String]) {
        self.version = version
        self.date = date
        self.lines = Array(lines.prefix(Self.shownLines))
    }

    /// From an appcast item's description (plain text or simple HTML).
    public init(version: String?, date: Date?, description: String?) {
        self.init(version: version, date: date, lines: Self.lines(description))
    }

    /// From a build's signed release notes: its summary, else nothing.
    public init(notes: ReleaseNotes, version: String?) {
        let lines = (notes.summary ?? []).map { "\(Self.groupTitle($0.group)): \($0.title)" }
        self.init(version: version ?? notes.shortVersion, date: Self.day(notes.date), lines: lines)
    }

    /// The detail line: "1.0.0 nightly 3801702 · Oct 10, 2026", or the
    /// version alone without a date; nil without either.
    public var detail: String? {
        let short = version.map(Self.shortVersion)
        let day = date?.formatted(date: .abbreviated, time: .omitted)
        switch (short, day) {
        case let (short?, day?): return UpdaterStrings.versionDate(short, day)
        case let (short?, nil): return short
        case let (nil, day?): return day
        case (nil, nil): return nil
        }
    }

    /// "1.0.0-nightly.3801702344901" reads "1.0.0 nightly 3801702": the
    /// run number's first 7 digits are enough to tell builds apart.
    public static func shortVersion(_ version: String) -> String {
        let parts = version.split(separator: "-", maxSplits: 1)
        guard parts.count == 2 else { return version }
        let channel = parts[1].split(separator: ".", maxSplits: 1)
        guard channel.count == 2, channel[1].allSatisfy(\.isNumber) else { return version }
        return "\(parts[0]) \(channel[0]) \(channel[1].prefix(7))"
    }

    /// Non-empty lines of a description, markup and list markers removed.
    static func lines(_ description: String?) -> [String] {
        guard let description else { return [] }
        let plain = description.replacingOccurrences(of: "<br\\s*/?>|</p>|</li>", with: "\n", options: .regularExpression)
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        return plain.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "-•* ")) }
            .filter { !$0.isEmpty }
    }

    static func groupTitle(_ group: String) -> String {
        switch group {
        case "new": UpdaterStrings.changelogNew
        case "fixed": UpdaterStrings.changelogFixed
        default: UpdaterStrings.changelogChanged
        }
    }

    /// "2026-10-10" as a date.
    static func day(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: text)
    }
}
