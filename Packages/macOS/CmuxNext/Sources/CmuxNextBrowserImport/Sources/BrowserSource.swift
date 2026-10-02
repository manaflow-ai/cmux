public import Foundation

/// A browser found on this Mac, with its profiles.
public struct BrowserSource: Sendable, Identifiable, Equatable {
    public var browser: ImportBrowser
    /// The installed app, when one was found (icon, "installed" label).
    public var appURL: URL?
    public var profiles: [BrowserSourceProfile]
    /// Set when the data directory exists but macOS blocks reading it.
    public var needsFullDiskAccess: Bool

    public var id: String { browser.rawValue }

    public init(browser: ImportBrowser, appURL: URL?, profiles: [BrowserSourceProfile], needsFullDiskAccess: Bool = false) {
        self.browser = browser
        self.appURL = appURL
        self.profiles = profiles
        self.needsFullDiskAccess = needsFullDiskAccess
    }
}

/// One profile of a source browser ("Default", "Profile 1", a Firefox
/// profile folder, or Safari's single store).
public struct BrowserSourceProfile: Sendable, Identifiable, Hashable, Codable {
    public var browser: ImportBrowser
    /// The folder name inside the data directory ("Default", "Profile 2",
    /// "Profiles/abcd.default-release"); stable across launches.
    public var directoryName: String
    /// The name the source shows ("Work", "Personal").
    public var displayName: String
    /// Absolute path of the profile folder.
    public var path: URL
    public var availability: [ImportDataKind: DataAvailability]
    /// The profile's account picture, when the source saved one (Chromium).
    public var avatar: URL?

    /// `<browser>/<directory>`: stable key for mappings and stored data.
    public var id: String { "\(browser.rawValue)/\(directoryName)" }

    public init(browser: ImportBrowser, directoryName: String, displayName: String, path: URL,
                availability: [ImportDataKind: DataAvailability], avatar: URL? = nil) {
        self.browser = browser
        self.directoryName = directoryName
        self.displayName = displayName
        self.path = path
        self.availability = availability
        self.avatar = avatar
    }

    public func availability(of kind: ImportDataKind) -> DataAvailability {
        availability[kind] ?? .absent
    }

    /// Kinds this profile can import now.
    public var importableKinds: [ImportDataKind] {
        ImportDataKind.allCases.filter { availability(of: $0).isImportable }
    }
}
