public import Foundation

/// The apps that open a file, and opening a file with one of them: the seam behind Open With.
/// The app passes `WorkspaceFileApps` (NSWorkspace); tests pass a fake.
public protocol FileAppsProviding: Sendable {
    /// The Open With rows for an item named `name` (`isDirectory`: a folder or package).
    func openWithList(forFileNamed name: String, isDirectory: Bool) async -> OpenWithList

    /// Opens `files` with the app at `app` (no activation wait on the caller).
    func open(_ files: [URL], withApplicationAt app: URL) async -> Bool
}
