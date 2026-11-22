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
        guard let object = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] else { return nil }
        func date(_ value: Any?) -> Date? {
            guard let ms = (value as? NSNumber)?.doubleValue, ms > 0 else { return nil }
            return Date(timeIntervalSince1970: ms / 1000)
        }
        let rows = (object["passwords"] as? [[String: Any]] ?? []).compactMap { row -> Row? in
            guard let id = row["id"] as? String, !id.isEmpty else { return nil }
            return Row(id: id, site: row["site"] as? String ?? "", url: row["url"] as? String ?? "",
                       username: row["username"] as? String ?? "", created: date(row["created"]), lastUsed: date(row["last_used"]),
                       timesUsed: (row["times_used"] as? NSNumber)?.intValue ?? 0, weak: row["weak"] as? Bool ?? false,
                       reused: row["reused"] as? Bool ?? false)
        }
        let exceptions = (object["exceptions"] as? [[String: Any]] ?? []).compactMap { row -> Exception? in
            guard let id = row["id"] as? String, !id.isEmpty else { return nil }
            return Exception(id: id, site: row["site"] as? String ?? "")
        }
        return ChromiumPasswordList(passwords: rows, exceptions: exceptions)
    }
}
