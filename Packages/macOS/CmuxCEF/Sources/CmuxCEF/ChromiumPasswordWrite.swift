public import Foundation

/// C-compatible password rows for the fork's profile import calls.
///
/// The fork copies every row synchronously before the import function returns.
/// The row buffer and all string storage are zeroed on that boundary and again
/// during deinitialization. Callers must keep each input password buffer alive
/// until the import call returns.
public nonisolated final class ChromiumPasswordRows: @unchecked Sendable {
    /// `cmux_shim_password_entry`'s documented size and field offsets.
    public static let stride = 72

    public typealias Row = (
        url: String,
        signonRealm: String,
        username: String,
        password: UnsafeRawBufferPointer,
        created: Date?
    )

    public let count: Int
    public let rows: UnsafeMutableRawPointer
    private var strings: [UnsafeMutableBufferPointer<UInt8>] = []
    private var afterCopy: (() -> Void)?

    /// Creates rows whose secret pointers remain valid until ``copied()`` or deinit.
    public init(_ entries: [Row], afterCopy: (() -> Void)? = nil) {
        self.afterCopy = afterCopy
        count = entries.count
        rows = UnsafeMutableRawPointer.allocate(byteCount: max(count, 1) * Self.stride, alignment: 8)
        rows.initializeMemory(as: UInt8.self, repeating: 0, count: max(count, 1) * Self.stride)
        for (index, entry) in entries.enumerated() {
            let row = rows + index * Self.stride
            store(entry.url, in: row, offset: 0)
            store(entry.signonRealm, in: row, offset: 16)
            store(entry.username, in: row, offset: 32)
            row.storeBytes(of: entry.password.baseAddress, toByteOffset: 48, as: UnsafeRawPointer?.self)
            row.storeBytes(of: entry.password.count, toByteOffset: 56, as: Int.self)
            let created = entry.created.map { Int64(($0.timeIntervalSince1970 + 11_644_473_600) * 1_000_000) } ?? 0
            row.storeBytes(of: created, toByteOffset: 64, as: Int64.self)
        }
    }

    /// Zeroes the row, string, and caller-owned password buffers after the shim copied them.
    public func copied() {
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

    private func store(_ text: String, in row: UnsafeMutableRawPointer, offset: Int) {
        let bytes = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: max(text.utf8.count, 1))
        _ = bytes.initialize(from: text.utf8)
        strings.append(bytes)
        row.storeBytes(of: UnsafeRawPointer(bytes.baseAddress), toByteOffset: offset, as: UnsafeRawPointer?.self)
        row.storeBytes(of: text.utf8.count, toByteOffset: offset + 8, as: Int.self)
    }
}

/// Counts returned by the fork's password import operation.
public nonisolated struct ChromiumPasswordWriteResult: Sendable, Equatable {
    public var added: Int
    public var duplicate: Int
    public var conflict: Int
    public var rejected: Int
    /// Input-row indices that conflict when API 20 reports them.
    public var conflictIndices: [Int]

    public init(added: Int, duplicate: Int, conflict: Int, rejected: Int, conflictIndices: [Int] = []) {
        self.added = added
        self.duplicate = duplicate
        self.conflict = conflict
        self.rejected = rejected
        self.conflictIndices = conflictIndices
    }

    public var storeFailed: Bool { min(added, duplicate, conflict, rejected) < 0 }

    /// Parses `{"added","duplicate","conflict","rejected","conflicts"}`.
    public static func parse(_ json: String) -> ChromiumPasswordWriteResult? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let added = object["added"] as? Int,
              let duplicate = object["duplicate"] as? Int,
              let conflict = object["conflict"] as? Int,
              let rejected = object["rejected"] as? Int else { return nil }
        return ChromiumPasswordWriteResult(
            added: added,
            duplicate: duplicate,
            conflict: conflict,
            rejected: rejected,
            conflictIndices: object["conflicts"] as? [Int] ?? []
        )
    }
}

/// Counts returned when an import conflict is explicitly replaced.
public nonisolated struct ChromiumPasswordReplaceResult: Sendable, Equatable {
    public var updated: Int
    public var missing: Int
    public var rejected: Int

    public init(updated: Int, missing: Int, rejected: Int) {
        self.updated = updated
        self.missing = missing
        self.rejected = rejected
    }

    public var storeFailed: Bool { min(updated, missing, rejected) < 0 }

    /// Parses `{"updated","missing","rejected"}`.
    public static func parse(_ json: String) -> ChromiumPasswordReplaceResult? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let updated = object["updated"] as? Int,
              let missing = object["missing"] as? Int,
              let rejected = object["rejected"] as? Int else { return nil }
        return ChromiumPasswordReplaceResult(updated: updated, missing: missing, rejected: rejected)
    }
}
