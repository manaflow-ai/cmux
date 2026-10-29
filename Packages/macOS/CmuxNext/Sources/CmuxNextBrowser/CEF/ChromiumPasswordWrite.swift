import CmuxNextCompat
public import Foundation

/// Rows for the shim's `cmux_shim_password_entry` array, written at the C
/// offsets the header documents (72 bytes each). The non-secret fields are
/// copied here; each password is only a pointer into the caller's own
/// buffer, which must stay alive and unchanged until `importPasswords`
/// returns (the shim copies everything before it returns). The row buffer is
/// zeroed before it is freed.
///
/// Not `Sendable`: the rows are built, handed to the shim and zeroed in one
/// isolation domain (the import's write on the main actor), so the compiler
/// keeps `copied()` and the buffers from being reached from two threads.
///
/// Memory safety: the row buffer is this object's own allocation of
/// `max(count, 1) * stride` bytes, and every write below stays inside row `index < count` at an offset
/// under `stride` (the header's field offsets); the password pointers are the caller's, valid while it
/// holds them (``init(_:afterCopy:)``).
@safe
public nonisolated final class ChromiumPasswordRows {
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
        // SAFETY (this initializer): the buffer is allocated and zeroed here at its full size; row `index` is
        // `index * stride` bytes in, under `count * stride`, and each field ends by offset 72 == stride.
        unsafe rows = UnsafeMutableRawPointer.allocate(byteCount: max(count, 1) * Self.stride, alignment: 8)
        unsafe rows.initializeMemory(as: UInt8.self, repeating: 0, count: max(count, 1) * Self.stride)
        for (index, entry) in unsafe entries.enumerated() {
            let row = unsafe rows + index * Self.stride
            unsafe store(entry.url, at: row, 0)
            unsafe store(entry.signonRealm, at: row, 16)
            unsafe store(entry.username, at: row, 32)
            unsafe row.storeBytes(of: entry.password.baseAddress, toByteOffset: 48, as: UnsafeRawPointer?.self)
            unsafe row.storeBytes(of: entry.password.count, toByteOffset: 56, as: Int.self)
            let created = unsafe entry.created.map { Int64(($0.timeIntervalSince1970 + 11_644_473_600) * 1_000_000) } ?? 0
            unsafe row.storeBytes(of: created, toByteOffset: 64, as: Int64.self)
        }
    }

    /// The shim has copied every row (or never will): zero the passwords and the copies here now.
    func copied() {
        afterCopy?()
        afterCopy = nil
        // SAFETY: zeroes this object's own row buffer and string copies, each at its allocated size.
        _ = unsafe memset_s(rows, max(count, 1) * Self.stride, 0, max(count, 1) * Self.stride)
        for string in unsafe strings { _ = unsafe memset_s(string.baseAddress, string.count, 0, string.count) }
    }

    deinit {
        copied()
        // SAFETY: the buffer and string copies are this object's own allocations, freed once here.
        _ = unsafe memset_s(rows, max(count, 1) * Self.stride, 0, max(count, 1) * Self.stride)
        unsafe rows.deallocate()
        for string in unsafe strings {
            _ = unsafe memset_s(string.baseAddress, string.count, 0, string.count)
            unsafe string.deallocate()
        }
    }

    /// Copies `text` and writes its pointer and length at `offset` of `row`, a row of this object's buffer.
    private func store(_ text: String, at row: UnsafeMutableRawPointer, _ offset: Int) {
        // SAFETY: the copy is allocated at the text's size (one byte at least) and freed in deinit; `row` and
        // `offset` are a row and a field of the buffer (init), the 16 bytes written end inside the row.
        let bytes = unsafe UnsafeMutableBufferPointer<UInt8>.allocate(capacity: max(text.utf8.count, 1))
        _ = unsafe bytes.initialize(from: text.utf8)
        unsafe strings.append(bytes)
        unsafe row.storeBytes(of: UnsafeRawPointer(bytes.baseAddress), toByteOffset: offset, as: UnsafeRawPointer?.self)
        unsafe row.storeBytes(of: text.utf8.count, toByteOffset: offset + 8, as: Int.self)
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
        guard let object = try? JSONSerialization.blockingJSONObject(with: Data(json.utf8)) as? [String: Any],
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
        guard let object = try? JSONSerialization.blockingJSONObject(with: Data(json.utf8)) as? [String: Any],
              let updated = object["updated"] as? Int, let missing = object["missing"] as? Int,
              let rejected = object["rejected"] as? Int else { return nil }
        return ChromiumPasswordReplaceResult(updated: updated, missing: missing, rejected: rejected)
    }
}
