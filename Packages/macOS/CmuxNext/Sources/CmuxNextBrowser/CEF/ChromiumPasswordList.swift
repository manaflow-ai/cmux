public import Foundation

/// The saved sign-ins and never-save sites of one Chromium profile, from the fork's
/// `cmux_password_list` (API 18). Metadata only: the fork never puts a password in it.
public nonisolated struct ChromiumPasswordList: Sendable, Hashable {
    public struct Row: Sendable, Hashable {
        /// The store's primary key as a decimal string (the key of every other call).
        public var id: String
        public var site: String
        public var url: String
        public var username: String
        public var created: Date?
        public var lastUsed: Date?
        public var timesUsed: Int
        public var weak: Bool
        public var reused: Bool

        public init(id: String, site: String, url: String, username: String, created: Date?, lastUsed: Date?, timesUsed: Int,
                    weak: Bool, reused: Bool) {
            self.id = id
            self.site = site
            self.url = url
            self.username = username
            self.created = created
            self.lastUsed = lastUsed
            self.timesUsed = timesUsed
            self.weak = weak
            self.reused = reused
        }
    }

    public struct Exception: Sendable, Hashable {
        public var id: String
        public var site: String

        public init(id: String, site: String) {
            self.id = id
            self.site = site
        }
    }

    public var passwords: [Row]
    public var exceptions: [Exception]

    public init(passwords: [Row], exceptions: [Exception]) {
        self.passwords = passwords
        self.exceptions = exceptions
    }

    /// The fork's JSON `{"passwords": [...], "exceptions": [...]}`; nil when it is not that object.
    public static func parse(_ json: String) -> ChromiumPasswordList? {
        nil
    }
}
