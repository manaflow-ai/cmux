public import Foundation

/// Rows for the shim's `cmux_shim_password_entry` array, written at the C
/// offsets the header documents (72 bytes each). The non-secret fields are
/// copied here; each password is only a pointer into the caller's own
/// buffer, which must stay alive and unchanged until `importPasswords`
/// returns (the shim copies everything before it returns). The row buffer is
/// zeroed before it is freed.
public nonisolated final class ChromiumPasswordRows: @unchecked Sendable {
    static let stride = 72
    let count: Int
    let rows: UnsafeMutableRawPointer
    private var strings: [UnsafeMutableBufferPointer<UInt8>] = []
    private var afterCopy: (() -> Void)?

    /// `password` is a pointer and a length into memory the caller owns.
    public typealias Row = (url: String, signonRealm: String, username: String, password: UnsafeRawBufferPointer, created: Date?)

    /// `afterCopy` zeroes the caller's passwords; it runs once, as soon as the shim has copied them.
    public init(_ entries: [Row], afterCopy: (() -> Void)? = nil) {
        self.afterCopy = afterCopy
        count = entries.count
        rows = UnsafeMutableRawPointer.allocate(byteCount: max(count, 1) * Self.stride, alignment: 8)
        rows.initializeMemory(as: UInt8.self, repeating: 0, count: max(count, 1) * Self.stride)
        for (index, entry) in entries.enumerated() {
            let row = rows + index * Self.stride
            store(entry.url, at: row, 0)
            store(entry.signonRealm, at: row, 16)
            store(entry.username, at: row, 32)
            row.storeBytes(of: entry.password.baseAddress, toByteOffset: 48, as: UnsafeRawPointer?.self)
            row.storeBytes(of: entry.password.count, toByteOffset: 56, as: Int.self)
            let created = entry.created.map(ChromiumCookieWrite.microseconds(since1601:)) ?? 0
            row.storeBytes(of: created, toByteOffset: 64, as: Int64.self)
        }
    }

    /// The shim has copied every row (or never will): zero the passwords and the copies here now.
    func copied() {
        afterCopy?()
        afterCopy = nil
        _ = memset_s(rows, max(count, 1) * Self.stride, 0, max(count, 1) * Self.stride)
        for string in strings { _ = memset_s(string.baseAddress, string.count, 0, string.count) }
    }

    deinit {
        copied()
        _ = memset_s(rows, max(count, 1) * Self.stride, 0, max(count, 1) * Self.stride)
        rows.deallocate()
        for string in strings {
            _ = memset_s(string.baseAddress, string.count, 0, string.count)
            string.deallocate()
        }
    }

    private func store(_ text: String, at row: UnsafeMutableRawPointer, _ offset: Int) {
        let bytes = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: max(text.utf8.count, 1))
        _ = bytes.initialize(from: text.utf8)
        strings.append(bytes)
        row.storeBytes(of: UnsafeRawPointer(bytes.baseAddress), toByteOffset: offset, as: UnsafeRawPointer?.self)
        row.storeBytes(of: text.utf8.count, toByteOffset: offset + 8, as: Int.self)
    }
}

/// What Chromium's password store did with an import. Counts only.
public nonisolated struct ChromiumPasswordWriteResult: Sendable, Equatable {
    public var added: Int
    public var duplicate: Int
    public var conflict: Int
    public var rejected: Int
    /// The rows saved with another password, indices into the rows written;
    /// empty when the fork does not list them (before API 20).
    public var conflictIndices: [Int]

    public init(added: Int, duplicate: Int, conflict: Int, rejected: Int, conflictIndices: [Int] = []) {
        self.added = added
        self.duplicate = duplicate
        self.conflict = conflict
        self.rejected = rejected
        self.conflictIndices = conflictIndices
    }

    /// The store failed the write: the fork answers that with -1 counts
    /// (API 20), which are never counts to show.
    public var storeFailed: Bool { min(added, duplicate, conflict, rejected) < 0 }

    /// Parses the shim's reply `{"added","duplicate","conflict","rejected","conflicts"?}`.
    static func parse(_ json: String) -> ChromiumPasswordWriteResult? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let added = object["added"] as? Int, let duplicate = object["duplicate"] as? Int,
              let conflict = object["conflict"] as? Int, let rejected = object["rejected"] as? Int else { return nil }
        return ChromiumPasswordWriteResult(added: added, duplicate: duplicate, conflict: conflict, rejected: rejected,
                                           conflictIndices: object["conflicts"] as? [Int] ?? [])
    }
}

/// The counts of a Replace: `updated` saved over a conflicting sign-in,
/// `missing` no longer saved (removed meanwhile), `rejected` not a sign-in.
public nonisolated struct ChromiumPasswordReplaceResult: Sendable, Equatable {
    public var updated: Int
    public var missing: Int
    public var rejected: Int

    public init(updated: Int, missing: Int, rejected: Int) {
        self.updated = updated
        self.missing = missing
        self.rejected = rejected
    }

    /// The store failed the write (-1 counts from the fork).
    public var storeFailed: Bool { min(updated, missing, rejected) < 0 }

    /// Parses the shim's reply `{"updated","missing","rejected"}`.
    static func parse(_ json: String) -> ChromiumPasswordReplaceResult? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let updated = object["updated"] as? Int, let missing = object["missing"] as? Int,
              let rejected = object["rejected"] as? Int else { return nil }
        return ChromiumPasswordReplaceResult(updated: updated, missing: missing, rejected: rejected)
    }
}
