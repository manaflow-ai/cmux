public import AppKit
import CmuxNextDesign

/// Development window: one terminal surface on a local shell PTY, with a
/// live hover-preview mirror in the corner. Lets the terminal module be
/// exercised before the daemon client exists. Not reachable in release UI.
public struct TerminalDebugWindow {
    public init() {}
    private static var controllers: [NSWindowController] = []

    fileprivate static func remove(_ controller: NSWindowController) {
        controllers.removeAll { $0 === controller }
    }
}
