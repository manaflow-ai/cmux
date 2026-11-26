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

/// A picked file kept by its URL, never a copy of its bytes (attachments
/// have no size cap). Files lets the app read it only inside its security
/// scope, and the picker closes that scope right after the pick, so every
/// reader (a preview, the player, an upload) opens it around its own use:
/// `withAccess` for one read, `open()` for a use that outlives a call.
public struct ScopedFile: Sendable {
    public let url: URL
    let scope: any SecurityScope

    public init(_ url: URL, scope: any SecurityScope = SystemSecurityScope()) {
        self.url = url
        self.scope = scope
    }

    /// Runs `body` with the scope open and closes it after, also when `body` throws.
    public func withAccess<T>(_ body: (URL) throws -> T) rethrows -> T {
        let access = open()
        defer { access.close() }
        return try body(access.url)
    }

    /// Opens the scope until the access is closed or released, whichever comes first.
    public func open() -> Access {
        Access(url: url, scope: scope, started: scope.startAccessing(url))
    }

    /// An open security scope: stops once, on `close()` or on deinit.
    public final class Access: @unchecked Sendable {
        public let url: URL
        private let scope: any SecurityScope
        private let lock = NSLock()
        /// Only touched under `lock`.
        private var started: Bool

        init(url: URL, scope: any SecurityScope, started: Bool) {
            self.url = url
            self.scope = scope
            self.started = started
        }

        public func close() {
            let stop = lock.withLock { () -> Bool in
                defer { started = false }
                return started
            }
            if stop { scope.stopAccessing(url) }
        }

        deinit { close() }
    }
}
