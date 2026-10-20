public import Foundation

/// What the pane asks of the system to open and reveal files. The app passes
/// its implementation (cmux opens and reveals off the main thread, cx-050n);
/// tests pass a recorder. Disk changes go through CmuxNextFiles' ``FileOperating``.
@MainActor
public protocol ScreenshotsWorkspace: AnyObject {
    /// Opens each file in its default app.
    ///
    /// - Parameter urls: the files.
    func open(_ urls: [URL])

    /// Selects the files in a Finder window.
    ///
    /// - Parameter urls: the files.
    func reveal(_ urls: [URL])
}
