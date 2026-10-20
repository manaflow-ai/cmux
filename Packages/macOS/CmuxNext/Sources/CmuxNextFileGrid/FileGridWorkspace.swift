public import AppKit

/// What a grid asks of the system to open, reveal and trash files, and the
/// dialogs it shows. The app passes its implementation (cmux opens and reveals
/// off the main thread, cx-050n; dialogs are cmux dialogs that show their keys,
/// u2647); tests pass a recorder.
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

    /// Asks for a new name (Rename).
    ///
    /// - Parameters:
    ///   - title: the question.
    ///   - initial: the current name.
    ///   - confirm: the confirming button's title.
    ///   - cancel: the cancel button's title.
    ///   - window: the window the dialog blocks; nil for none.
    /// - Returns: the typed name, or nil when cancelled.
    func askName(title: String, initial: String, confirm: String, cancel: String, in window: NSWindow?) async -> String?

    /// Says why a command failed.
    ///
    /// - Parameters:
    ///   - message: what failed.
    ///   - detail: the reason, when there is one.
    ///   - window: the window the dialog blocks; nil for none.
    func report(_ message: String, detail: String?, in window: NSWindow?)
}
