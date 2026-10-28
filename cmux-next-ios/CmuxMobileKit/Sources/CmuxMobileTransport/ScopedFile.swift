import Foundation

/// Opens and closes a URL's security scope: the system's for a Files pick,
/// a recording one in tests.
public protocol SecurityScope: Sendable {
    /// Opens access; false when the URL has no scope (an app file), which is then never stopped.
    func startAccessing(_ url: URL) -> Bool
    func stopAccessing(_ url: URL)
}

/// The system's security scope (`startAccessingSecurityScopedResource`).
public struct SystemSecurityScope: SecurityScope {
    public init() {}

    public func startAccessing(_ url: URL) -> Bool { url.startAccessingSecurityScopedResource() }
    public func stopAccessing(_ url: URL) { url.stopAccessingSecurityScopedResource() }
}

/// A picked file kept by its URL. Stub: it does not open the scope yet.
public struct ScopedFile: Sendable {
    public let url: URL
    let scope: any SecurityScope

    public init(_ url: URL, scope: any SecurityScope = SystemSecurityScope()) {
        self.url = url
        self.scope = scope
    }

    /// Stub: runs `body` without opening the scope.
    public func withAccess<T>(_ body: (URL) throws -> T) rethrows -> T {
        try body(url)
    }

    /// Stub: an access that never opened the scope.
    public func open() -> Access {
        Access(url: url)
    }

    /// Stub: closing does nothing.
    public final class Access: Sendable {
        public let url: URL

        init(url: URL) { self.url = url }

        public func close() {}
    }
}
