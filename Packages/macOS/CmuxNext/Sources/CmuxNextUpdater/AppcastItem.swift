public import Foundation

/// One `<item>` of a Sparkle appcast: the fields that decide whether this Mac is offered the
/// update. ``AppcastParser`` reads them and ``AppcastSelector`` decides with the update rules
/// (cmux-updater-core).
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

    /// The item as the update rules read and write it: URLs as text, the date in seconds since 1970.
    nonisolated struct Wire: Codable, Sendable {
        var version: String
        var displayVersion: String
        var title: String?
        var minimumSystemVersion: SystemVersion?
        var maximumSystemVersion: SystemVersion?
        var releaseNotesUrl: String?
        var downloadUrl: String?
        var itemDescription: String?
        var date: Double?
        var sparkleChannel: String?
        var listsDeltas: Bool

        init(_ item: AppcastItem) {
            version = item.version
            displayVersion = item.displayVersion
            title = item.title
            minimumSystemVersion = item.minimumSystemVersion
            maximumSystemVersion = item.maximumSystemVersion
            releaseNotesUrl = item.releaseNotesURL?.absoluteString
            downloadUrl = item.downloadURL?.absoluteString
            itemDescription = item.itemDescription
            date = item.date?.timeIntervalSince1970
            sparkleChannel = item.sparkleChannel
            listsDeltas = item.listsDeltas
        }

        var item: AppcastItem {
            AppcastItem(version: version, displayVersion: displayVersion, title: title,
                        minimumSystemVersion: minimumSystemVersion, maximumSystemVersion: maximumSystemVersion,
                        releaseNotesURL: releaseNotesUrl.flatMap(URL.init(string:)),
                        downloadURL: downloadUrl.flatMap(URL.init(string:)), itemDescription: itemDescription,
                        date: date.map(Date.init(timeIntervalSince1970:)), sparkleChannel: sparkleChannel,
                        listsDeltas: listsDeltas)
        }
    }
}

/// The appcast was not a readable Sparkle feed.
nonisolated public struct AppcastParseError: Error, Equatable, CustomStringConvertible {
    public let message: String
    public var description: String { message }
}
