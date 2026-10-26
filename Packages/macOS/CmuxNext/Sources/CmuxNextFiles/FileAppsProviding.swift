public import Foundation

/// The apps that open a file, and opening a file with one of them: the seam behind Open With.
/// The app passes `WorkspaceFileApps` (Launch Services on the system lane); tests pass a fake.
public protocol FileAppsProviding: Sendable {
    /// The Open With rows for an item named `name` (`isDirectory`: a folder or package).
    func openWithList(forFileNamed name: String, isDirectory: Bool) async -> OpenWithList

    /// The Open With rows for an item named `name` when they are at hand now (kept from an earlier ask), else nil:
    /// a menu fills its submenu from them in the turn it opens.
    @MainActor func keptOpenWithList(forFileNamed name: String, isDirectory: Bool) -> OpenWithList?

    /// Warms the Open With rows of `items` (the rows on screen), so a right-click on one of them fills its submenu
    /// in the turn it opens.
    @MainActor func prefetchOpenWithLists(for items: [(name: String, isDirectory: Bool)])

    /// Opens `files` with the app at `app` (no activation wait on the caller).
    func open(_ files: [URL], withApplicationAt app: URL) async -> Bool
}

extension FileAppsProviding {
    /// Nothing is kept: the menu waits for ``openWithList(forFileNamed:isDirectory:)``.
    @MainActor public func keptOpenWithList(forFileNamed name: String, isDirectory: Bool) -> OpenWithList? { nil }

    /// Nothing to warm.
    @MainActor public func prefetchOpenWithLists(for items: [(name: String, isDirectory: Bool)]) {}
}
