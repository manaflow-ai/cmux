public import Foundation

/// The audit ledger of cookie imports (a Repository): one ``CookieImportRecord`` per request,
/// whatever its outcome, newest last, in one JSON file only this user can read (mode 600). It
/// keeps the newest ``limit`` records. Nothing in it is a cookie value.
///
/// ```swift
/// let ledger = CookieImportLedger(file: directory.appending(path: "cookie-imports.json"))
/// await ledger.append(record)
/// let shown = await ledger.records()
/// ```
public actor CookieImportLedger {
    /// The most records kept; older ones drop off.
    public static let limit = 200

    private let file: URL
    private var loaded: [CookieImportRecord]?

    /// - Parameter file: The ledger's JSON file (made with its folder on the first write).
    public init(file: URL) {
        self.file = file
    }

    /// `Application Support/cmux-next/<bundle id>/cookie-imports.json`.
    public static var defaultFile: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "cmux-next", directoryHint: .isDirectory)
            .appending(path: Bundle.main.bundleIdentifier ?? "com.cmuxterm.app.next", directoryHint: .isDirectory)
            .appending(path: "cookie-imports.json")
    }

    /// Every kept record, oldest first.
    public func records() -> [CookieImportRecord] {
        current()
    }

    /// The record with `id`, nil when the ledger has none.
    public func record(_ id: String) -> CookieImportRecord? {
        current().first { $0.id == id }
    }

    /// Adds `record` and saves.
    public func append(_ record: CookieImportRecord) {
        var all = current()
        all.append(record)
        if all.count > Self.limit { all.removeFirst(all.count - Self.limit) }
        save(all)
    }

    /// Marks record `id` removed at `date` and saves; returns the updated record, nil when unknown.
    @discardableResult
    public func markRemoved(_ id: String, at date: Date) -> CookieImportRecord? {
        var all = current()
        guard let index = all.firstIndex(where: { $0.id == id }) else { return nil }
        all[index].removedAt = date
        save(all)
        return all[index]
    }

    private func current() -> [CookieImportRecord] {
        if let loaded { return loaded }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let read = (try? Data(contentsOf: file)).flatMap { try? decoder.decode([CookieImportRecord].self, from: $0) } ?? []
        loaded = read
        return read
    }

    private func save(_ all: [CookieImportRecord]) {
        loaded = all
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(all) else { return }
        let manager = FileManager.default
        try? manager.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Written whole and atomically, then owner-only: the ledger names sites the person is signed in to.
        guard (try? data.write(to: file, options: [.atomic])) != nil else { return }
        try? manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}
