import Foundation

// ``FolderBookmark`` keeps one folder the person picked across launches, for ``BrowserFolderGrants``: a
// security-scoped bookmark on Apple platforms (FolderBookmark+Apple.swift), where the sandbox lets the app
// read the folder only inside its scope, and the folder's path on Linux (FolderBookmark+Linux.swift), which has
// no sandbox scope to hold. Both have `make(_:)`, `resolve(_:)`, `startAccessing(_:)` and `stopAccessing(_:)`.
extension FolderBookmark {
    /// Runs `body` with every folder in `folders` in its scope, and gives each scope back after.
    static func accessing<T>(_ folders: [URL], _ body: () throws -> T) rethrows -> T {
        let scoped = folders.filter(startAccessing)
        defer { scoped.forEach(stopAccessing) }
        return try body()
    }
}
