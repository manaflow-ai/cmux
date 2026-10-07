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

    public init(version: String, displayVersion: String? = nil, title: String? = nil,
                minimumSystemVersion: SystemVersion? = nil, maximumSystemVersion: SystemVersion? = nil,
                releaseNotesURL: URL? = nil, downloadURL: URL? = nil) {
        self.version = version
        self.displayVersion = displayVersion ?? version
        self.title = title
        self.minimumSystemVersion = minimumSystemVersion
        self.maximumSystemVersion = maximumSystemVersion
        self.releaseNotesURL = releaseNotesURL
        self.downloadURL = downloadURL
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
