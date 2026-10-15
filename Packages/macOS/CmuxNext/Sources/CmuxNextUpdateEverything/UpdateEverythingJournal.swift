public import Foundation

/// The note an Update Everything run leaves before the app relaunches for its own update, so the
/// relaunched app (whose bundled daemon build is newer) finishes the run: it updates the machines
/// now behind it and continues threads. One small JSON file; a note older than ``maximumAge`` is
/// dropped, so a run that never relaunched does not wake up days later.
public actor UpdateEverythingJournal {
    /// What the relaunched app needs to finish the run.
    public nonisolated struct Entry: Sendable, Codable, Equatable {
        /// The person's "Continue threads after restarts".
        public var continueThreads: Bool
        /// When the run wrote the note.
        public var startedAt: Date
        /// The connected SSH and Cloud machines of the run: the relaunched app waits for them.
        public var machineIDs: [String]

        /// - Parameters:
        ///   - continueThreads: The person's choice in the confirmation.
        ///   - startedAt: When the run wrote the note.
        ///   - machineIDs: The run's SSH and Cloud machines.
        public init(continueThreads: Bool, startedAt: Date, machineIDs: [String]) {
            self.continueThreads = continueThreads
            self.startedAt = startedAt
            self.machineIDs = machineIDs
        }
    }

    /// Past this, a note is stale: the relaunch it waited for did not come from this run.
    public static let maximumAge: TimeInterval = 60 * 60

    private let url: URL
    private let now: @Sendable () -> Date

    /// - Parameters:
    ///   - url: The note's file, in the app's Application Support folder.
    ///   - now: The clock (tests pass a fixed date).
    public init(url: URL, now: @escaping @Sendable () -> Date = Date.init) {
        self.url = url
        self.now = now
    }

    /// Writes the note before the app relaunches.
    /// - Parameters:
    ///   - continueThreads: The person's choice in the confirmation.
    ///   - machineIDs: The run's SSH and Cloud machines.
    /// - Throws: The file write's error.
    public func save(continueThreads: Bool, machineIDs: [String]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(Entry(continueThreads: continueThreads, startedAt: now(), machineIDs: machineIDs)).write(to: url, options: .atomic)
    }

    /// Reads and removes the note: a run is finished at most once, even when finishing it crashes.
    /// - Returns: The note, or nil when there is none or it is stale.
    public func take() -> Entry? {
        defer { try? FileManager.default.removeItem(at: url) }
        guard let data = try? Data(contentsOf: url), let entry = try? JSONDecoder().decode(Entry.self, from: data) else { return nil }
        return now().timeIntervalSince(entry.startedAt) <= Self.maximumAge ? entry : nil
    }

    /// Removes the note without reading it (the app update did not start).
    public func clear() {
        try? FileManager.default.removeItem(at: url)
    }
}
