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
            let created = entry.created.map { Int64(($0.timeIntervalSince1970 + 11_644_473_600) * 1_000_000) } ?? 0
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

    public init(added: Int, duplicate: Int, conflict: Int, rejected: Int) {
        self.added = added
        self.duplicate = duplicate
        self.conflict = conflict
        self.rejected = rejected
    }

    /// Parses the shim's reply `{"added","duplicate","conflict","rejected"}`.
    static func parse(_ json: String) -> ChromiumPasswordWriteResult? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let added = object["added"] as? Int, let duplicate = object["duplicate"] as? Int,
              let conflict = object["conflict"] as? Int, let rejected = object["rejected"] as? Int else { return nil }
        return ChromiumPasswordWriteResult(added: added, duplicate: duplicate, conflict: conflict, rejected: rejected)
    }
}
