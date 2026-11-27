import Foundation

/// File names inside a profile folder, per data kind.
public struct BrowserDataFiles: Sendable, Codable, Equatable {
    public var bookmarks: String?
    public var history: String?
    public var passwords: String?
    public var cookies: String?
}

/// The Keychain item whose password encrypts a Chromium browser's cookies
/// and passwords. `confirmed` is false when the name was not seen on a
/// real install; a wrong name only makes that import report "key not found".
public struct SafeStorageItem: Sendable, Codable, Equatable {
    public var service: String
    /// The item's account when one service has two items (an Electron app
    /// keeps "<App> Key" beside "<App>"); nil matches the service alone.
    public var account: String?
    public var confirmed: Bool

    public init(service: String, account: String? = nil, confirmed: Bool) {
        self.service = service
        self.account = account
        self.confirmed = confirmed
    }
}

/// Where a row's facts come from: an official page or a file format seen
/// on a real install or in the vendor's docs.
public struct BrowserSourceEvidence: Sendable, Codable, Equatable {
    public var url: String
    public var note: String
}
