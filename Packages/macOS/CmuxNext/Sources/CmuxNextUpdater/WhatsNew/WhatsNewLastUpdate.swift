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
    /// The staged update's highlights as the popover showed them
    /// (cx-ncc.45.5); nil in records older builds wrote.
    public var highlights: UpdateHighlights?
    /// When the install was handed to Sparkle (the click, or a quit that installs); nil while
    /// the update only waits. A launch of `fromBuild` after it means the install did not take.
    public var installStartedAt: Date?
    /// Why the install did not take, when the old app saw it fail (Sparkle's error, the
    /// install watchdog's); nil when the app quit for the installer.
    public var installFailure: String?

    public init(fromVersion: String, fromBuild: String, toVersion: String, toBuild: String, stagedAt: Date,
                changelog: UpdateChangelog, highlights: UpdateHighlights? = nil, installStartedAt: Date? = nil,
                installFailure: String? = nil) {
        self.fromVersion = fromVersion
        self.fromBuild = fromBuild
        self.toVersion = toVersion
        self.toBuild = toBuild
        self.stagedAt = stagedAt
        self.changelog = changelog
        self.highlights = highlights
        self.installStartedAt = installStartedAt
        self.installFailure = installFailure
    }
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

    /// What a launch of `build` reads in the record the previous launch left.
    public enum Taken: Equatable, Sendable {
        /// This launch is the update the record describes.
        case installed(WhatsNewLastUpdate)
        /// The previous launch of this same build started installing the update, and the
        /// app was not replaced.
        case didNotInstall(WhatsNewLastUpdate)
    }

    /// The record as a launch of `build` reads it, or nil. Any other record (an update that
    /// only waited, an older one, an unreadable one) is removed.
    public func take(running build: String) -> Taken? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let record = try? decoder.decode(WhatsNewLastUpdate.self, from: data) {
            if record.toBuild == build { return .installed(record) }
            if record.fromBuild == build, record.installStartedAt != nil { return .didNotInstall(record) }
        }
        clear()
        return nil
    }

    /// Removes the record.
    public func clear() {
        try? FileManager.default.removeItem(at: url)
    }

    /// Removes the record only when it is still `record` (a newer update may have replaced it).
    public func clear(ifStill record: WhatsNewLastUpdate) {
        guard let data = try? Data(contentsOf: url) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard (try? decoder.decode(WhatsNewLastUpdate.self, from: data)) == record else { return }
        clear()
    }

    /// The user saw the update to `build` (page opened or card closed):
    /// removes the record only when it is that update's. A newer update may
    /// have staged since launch and written its own record, which the next
    /// launch shows.
    public func clear(ifFor build: String) {
        guard let data = try? Data(contentsOf: url) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let record = try? decoder.decode(WhatsNewLastUpdate.self, from: data), record.toBuild != build { return }
        clear()
    }
}
