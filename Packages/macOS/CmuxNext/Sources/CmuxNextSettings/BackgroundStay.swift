public import CmuxNextActions

/// What keeps cmux running hidden after a Quit (the background ready copy, `app.backgroundReady`), as
/// ``BackgroundActivation`` sees it: while it holds the app, background mode is entered with the windows
/// kept (ordered out, not closed), its menu's quit rows are its own, and leaving background mode for a
/// window brings back everything it hid.
@MainActor
public protocol BackgroundStay: AnyObject {
    /// The app is hidden by it (or started hidden at login): background mode, whatever windows it kept.
    var holdsBackground: Bool { get }
    /// The background menu's quit rows (Quit, and Quit Completely while the setting is on).
    var quitItems: [ActionID] { get }
    /// Background mode was left for a window that appears.
    func backgroundDidLeave()
}
