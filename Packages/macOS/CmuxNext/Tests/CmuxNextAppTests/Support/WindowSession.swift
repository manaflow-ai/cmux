import CoreGraphics
import Testing

/// Tests that need a window session: AppKit attaches sheets only when the
/// process runs in a console (window server) login session. The GUI lane
/// (cmux-lawrence-2) has one; the headless lent minis of `cmux-ci run` do not.
/// Use `.enabled(if: WindowSession.available, WindowSession.reason)`.
nonisolated enum WindowSession {
    static let reason: Comment = "AppKit sheets need a window session; headless lent minis have none"

    static var available: Bool {
        isWindowSession(CGSessionCopyCurrentDictionary() as? [String: Any])
    }

    /// A session dictionary of a console login session.
    static func isWindowSession(_ session: [String: Any]?) -> Bool {
        (session?[kCGSessionOnConsoleKey] as? Bool) == true
    }
}
