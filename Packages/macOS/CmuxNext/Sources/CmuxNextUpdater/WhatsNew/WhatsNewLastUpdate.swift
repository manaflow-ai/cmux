public import Foundation

/// The update this build came from (cx-ncc.45, decision D1 2026-10-10:
/// What's New after every update, nightly included, once, no modal). The
/// old app writes it when the update stages (``WhatsNewLastUpdateStore``);
/// the new app reads it once at launch and shows it on the "cmux Updated!"
/// card and at the top of the What's New page until the user opens the
/// page or closes the card.
nonisolated public struct WhatsNewLastUpdate: Codable, Equatable, Sendable {
    /// `CFBundleShortVersionString` and `CFBundleVersion` before the update.
    public var fromVersion: String
    public var fromBuild: String
    /// The staged build (this launch's build once the update installed).
    public var toVersion: String
    public var toBuild: String
    /// When the update staged.
    public var stagedAt: Date
    /// The staged update's changelog (the update cards' type, cx-lntk).
    public var changelog: UpdateChangelog

    public init(fromVersion: String, fromBuild: String, toVersion: String, toBuild: String, stagedAt: Date,
                changelog: UpdateChangelog) {
        self.fromVersion = fromVersion
        self.fromBuild = fromBuild
        self.toVersion = toVersion
        self.toBuild = toBuild
        self.stagedAt = stagedAt
        self.changelog = changelog
    }

    /// The record as a What's New document, for the page (feed origin: it
    /// came from the appcast, so it has no try-it actions).
    public var document: WhatsNewDocument {
        let entries = changelog.lines.enumerated().map { index, line in
            let (category, title) = Self.categorized(line)
            return WhatsNewDocument.Entry(id: "update-\(toBuild)-\(index)", category: category,
                                          title: WhatsNewText(stringLiteral: title), summary: "")
        }
        let day = changelog.date.map { Self.dayFormatter.string(from: $0) } ?? Self.dayFormatter.string(from: stagedAt)
        return WhatsNewDocument(version: toVersion, channel: WhatsNewVersion(toVersion)?.prerelease?.kind == "nightly" ? .nightly : .stable,
                                date: day, headline: WhatsNewText(stringLiteral: changelog.detail ?? toVersion),
                                entries: entries, origin: .feed)
    }

    /// "New: X" / "Fixed: X" (English or this language's card labels).
    static func categorized(_ line: String) -> (WhatsNewDocument.Category, String) {
        let prefixes: [(WhatsNewDocument.Category, [String])] = [
            (.new, ["New", UpdaterStrings.changelogNew]),
            (.fixed, ["Fixed", UpdaterStrings.changelogFixed]),
            (.improved, ["Changed", "Improved", UpdaterStrings.changelogChanged]),
        ]
        for (category, words) in prefixes {
            for word in Set(words) where line.hasPrefix(word + ":") {
                return (category, line.dropFirst(word.count + 1).trimmingCharacters(in: .whitespaces))
            }
        }
        return (.improved, line)
    }

    static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}

/// Where the update record lives between the two processes: one small
/// JSON file in the app's Application Support folder, written atomically.
nonisolated public struct WhatsNewLastUpdateStore: Sendable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    /// `~/Library/Application Support/cmux-next/<bundle id>/last-update.json`.
    public static func app(bundleIdentifier: String?) -> WhatsNewLastUpdateStore {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return WhatsNewLastUpdateStore(url: support.appending(path: "cmux-next/\(bundleIdentifier ?? "cmux")/last-update.json",
                                                              directoryHint: .notDirectory))
    }

    /// Writes `record` (replacing an older one); false when it could not.
    @discardableResult
    public func write(_ record: WhatsNewLastUpdate) -> Bool {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(record) else { return false }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    /// The record for `build`, or nil. A record for another build (a
    /// staged update that never installed, or an older one) is removed.
    public func take(for build: String) -> WhatsNewLastUpdate? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let record = try? decoder.decode(WhatsNewLastUpdate.self, from: data), record.toBuild == build else {
            clear()
            return nil
        }
        return record
    }

    /// The user saw it (page opened or card closed).
    public func clear() {
        try? FileManager.default.removeItem(at: url)
    }
}
