public import Foundation

/// Metadata for the saved sign-ins and never-save sites of one Chromium profile.
///
/// Password bytes are deliberately absent. The CEF fork only returns these rows
/// as metadata so callers can render a profile-scoped list without exposing a
/// secret to the browser page, socket, or automation layers.
public nonisolated struct ChromiumPasswordList: Sendable, Hashable {
    /// One saved sign-in's metadata.
    public struct Row: Sendable, Hashable {
        /// The fork's decimal primary key used by remove/reveal operations.
        public var id: String
        public var site: String
        public var url: String
        public var username: String
        public var created: Date?
        public var lastUsed: Date?
        public var timesUsed: Int
        public var isWeak: Bool
        public var isReused: Bool

        public init(id: String, site: String, url: String, username: String, created: Date?, lastUsed: Date?,
                    timesUsed: Int, isWeak: Bool, isReused: Bool) {
            self.id = id
            self.site = site
            self.url = url
            self.username = username
            self.created = created
            self.lastUsed = lastUsed
            self.timesUsed = timesUsed
            self.isWeak = isWeak
            self.isReused = isReused
        }
    }

    /// A site for which Chromium should never offer to save a password.
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

    /// Parses the fork's metadata-only `{"passwords": [...], "exceptions": [...]}` reply.
    /// Rows without a non-empty id are ignored; malformed top-level JSON returns `nil`.
    public static func parse(_ json: String) -> ChromiumPasswordList? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else {
            return nil
        }
        let passwords = (object["passwords"] as? [[String: Any]] ?? []).compactMap { row -> Row? in
            guard let id = row["id"] as? String, !id.isEmpty else { return nil }
            return Row(
                id: id,
                site: row["site"] as? String ?? "",
                url: row["url"] as? String ?? "",
                username: row["username"] as? String ?? "",
                created: Self.date(fromMilliseconds: row["created"]),
                lastUsed: Self.date(fromMilliseconds: row["last_used"]),
                timesUsed: (row["times_used"] as? NSNumber)?.intValue ?? 0,
                isWeak: row["weak"] as? Bool ?? false,
                isReused: row["reused"] as? Bool ?? false
            )
        }
        let exceptions = (object["exceptions"] as? [[String: Any]] ?? []).compactMap { row -> Exception? in
            guard let id = row["id"] as? String, !id.isEmpty else { return nil }
            return Exception(id: id, site: row["site"] as? String ?? "")
        }
        return ChromiumPasswordList(passwords: passwords, exceptions: exceptions)
    }

    private static func date(fromMilliseconds value: Any?) -> Date? {
        guard let milliseconds = (value as? NSNumber)?.doubleValue, milliseconds > 0 else { return nil }
        return Date(timeIntervalSince1970: milliseconds / 1_000)
    }
}
