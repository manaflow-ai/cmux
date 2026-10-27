#if canImport(Darwin)
import Foundation

/// A picked folder as a bookmark: security-scoped where the process can make one, plain otherwise (an
/// unsandboxed process may not hold the scope, and needs none to read).
enum FolderBookmark {
    /// The bookmark of `folder`; nil when the system makes none.
    static func make(_ folder: URL) -> Data? {
        (try? folder.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil))
            ?? (try? folder.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil))
    }

    /// The folder `data` names; nil when it no longer resolves.
    static func resolve(_ data: Data) -> URL? {
        var stale = false
        return (try? URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale))
            ?? (try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale))
    }

    /// Takes `folder`'s security scope; false when it has none to take.
    static func startAccessing(_ folder: URL) -> Bool {
        folder.startAccessingSecurityScopedResource()
    }

    /// Gives back a scope ``startAccessing(_:)`` took.
    static func stopAccessing(_ folder: URL) {
        folder.stopAccessingSecurityScopedResource()
    }
}
#endif
