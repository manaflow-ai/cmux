public import Foundation

/// What a grid asks of the system to open, reveal and trash files. The app
/// passes its implementation (cmux opens and reveals off the main thread,
/// cx-050n); tests pass a recorder.
@MainActor
public protocol FileGridWorkspace: AnyObject {
    /// Opens each file in its default app.
    ///
    /// - Parameter urls: the files.
    func open(_ urls: [URL])

    /// Selects the files in a Finder window.
    ///
    /// - Parameter urls: the files.
    func reveal(_ urls: [URL])

    /// Moves the files to the Trash.
    ///
    /// - Parameter urls: the files.
    /// - Throws: the first file that could not be moved.
    func recycle(_ urls: [URL]) async throws
}
