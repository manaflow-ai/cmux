public import Foundation

/// One `<item>` of a Sparkle appcast: the fields that decide whether this
/// Mac is offered the update.
nonisolated public struct AppcastItem: Sendable, Equatable {
    /// `sparkle:version` (the bundle's `CFBundleVersion`).
    public var version: String
    /// `sparkle:shortVersionString`, else the version.
    public var displayVersion: String
    public var title: String?
    /// `sparkle:minimumSystemVersion`; nil offers the item to every macOS.
    public var minimumSystemVersion: SystemVersion?
    /// `sparkle:maximumSystemVersion`.
    public var maximumSystemVersion: SystemVersion?
    public var releaseNotesURL: URL?
    public var downloadURL: URL?
    /// The item's `<description>`: on nightly-next, a short plain-text
    /// changelog ("New: …", one line per change; cx-lntk).
    public var itemDescription: String?
    /// `<pubDate>`.
    public var date: Date?
    /// `sparkle:channel`; nil is Sparkle's default channel, which every updater accepts.
    public var sparkleChannel: String?
    /// Whether the item lists `sparkle:deltas` (nightly-next adds them minutes after the full archive).
    public var listsDeltas: Bool

    public init(version: String, displayVersion: String? = nil, title: String? = nil,
                minimumSystemVersion: SystemVersion? = nil, maximumSystemVersion: SystemVersion? = nil,
                releaseNotesURL: URL? = nil, downloadURL: URL? = nil, itemDescription: String? = nil, date: Date? = nil,
                sparkleChannel: String? = nil, listsDeltas: Bool = false) {
        self.itemDescription = itemDescription
        self.listsDeltas = listsDeltas
        self.sparkleChannel = sparkleChannel
        self.date = date
        self.version = version
        self.displayVersion = displayVersion ?? version
        self.title = title
        self.minimumSystemVersion = minimumSystemVersion
        self.maximumSystemVersion = maximumSystemVersion
        self.releaseNotesURL = releaseNotesURL
        self.downloadURL = downloadURL
    }

    /// Whether an updater that allows the `sparkle:channel` tags `channels` sees this item:
    /// untagged items always, tagged ones only when allowed.
    public func isOffered(allowing channels: Set<String>) -> Bool {
        sparkleChannel.map(channels.contains) ?? true
    }

    /// Whether Sparkle would offer this item on `system`.
    public func supports(_ system: SystemVersion) -> Bool {
        if let minimumSystemVersion, system < minimumSystemVersion { return false }
        if let maximumSystemVersion, system > maximumSystemVersion { return false }
        return true
    }
}

/// The appcast was not a readable Sparkle feed.
nonisolated public struct AppcastParseError: Error, Equatable, CustomStringConvertible {
    public let message: String
    public var description: String { message }
}
