public import Foundation

/// Reads and writes the browser profile book as JSON, off the main thread.
/// A missing or unreadable file loads a fresh book (only the default
/// profile); writes are atomic.
public actor BrowserProfileBookFile {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public func load() -> BrowserProfileBook {
        BrowserProfileBook() // stub
    }

    public func save(_ book: BrowserProfileBook) throws {}
}
