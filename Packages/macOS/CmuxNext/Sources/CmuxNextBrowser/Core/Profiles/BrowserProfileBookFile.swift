import CmuxNextCompat
public import Foundation

/// Reads and writes the browser profile book as JSON, off the main thread.
/// A missing or unreadable file loads a fresh book (only the default
/// profile); writes are atomic.
public actor BrowserProfileBookFile {
    /// The queue this actor runs on (threading-model.md, `com.cmuxterm.next.browser.profile-book`): its file reads and writes block a thread of
    /// its own, never a cooperative pool thread (the HomeCache pattern).
    // executor: com.cmuxterm.next.browser.profile-book
    private nonisolated let queue = DispatchSerialQueue(label: "com.cmuxterm.next.browser.profile-book", qos: .userInitiated)

    /// Runs the actor on ``queue``.
    public nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public func load() -> BrowserProfileBook {
        // concurrency-allow: actor-isolated; runs on the actor's executor, never the main thread.
        guard let data = try? Data(contentsOf: url),
              let book = try? JSONDecoder().blockingDecode(BrowserProfileBook.self, from: data) else { return BrowserProfileBook() }
        return book
    }

    public func save(_ book: BrowserProfileBook) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(book).write(to: url, options: .atomic)
    }
}
