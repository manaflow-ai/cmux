import CmuxNextDesign
import Foundation

/// Reasons `cmux window|pane|tab screenshot` gives. Keys live in
/// Resources/MiscHandlers.xcstrings.
enum ScreenshotStrings {
    static var outNeedsValue: String {
        String(localized: "handlers.screenshot.outNeedsValue", defaultValue: "out (--out) needs a file path, or - for the image inline",
               table: "MiscHandlers", bundle: .module)
    }
    static func outRelative(_ path: String) -> String {
        String(format: String(localized: "handlers.screenshot.outRelative", defaultValue: "out (--out) needs an absolute path or -, not “%@”",
                              table: "MiscHandlers", bundle: .module), path)
    }
    static func outIsFolder(_ path: String) -> String {
        String(format: String(localized: "handlers.screenshot.outIsFolder", defaultValue: "out (--out) names a folder, not a file: “%@”",
                              table: "MiscHandlers", bundle: .module), path)
    }
    static var notOnScreen: String {
        String(localized: "handlers.screenshot.notOnScreen", defaultValue: "The window is not on screen (the app is hidden or the window is closed)",
               table: "MiscHandlers", bundle: .module)
    }
    static var minimized: String {
        String(localized: "handlers.screenshot.minimized", defaultValue: "The window is minimized in the Dock; cmux does not restore it for a screenshot",
               table: "MiscHandlers", bundle: .module)
    }
    static var blank: String {
        String(localized: "handlers.screenshot.blank", defaultValue: "The window server gave no image of the window",
               table: "MiscHandlers", bundle: .module)
    }
    static var paneNotShown: String {
        String(localized: "handlers.screenshot.paneNotShown", defaultValue: "The pane is not on screen: no window shows its workspace",
               table: "MiscHandlers", bundle: .module)
    }
    static var outsideWindow: String {
        String(localized: "handlers.screenshot.outsideWindow", defaultValue: "The pane is outside the window's visible area",
               table: "MiscHandlers", bundle: .module)
    }
    static var terminalNotShown: String {
        String(localized: "handlers.screenshot.terminalNotShown",
               defaultValue: "The terminal tab is not on screen. Read its text with `cmux terminal <id> screen read`, or show its workspace and retry",
               table: "MiscHandlers", bundle: .module)
    }
    static var tabNotShown: String {
        String(localized: "handlers.screenshot.tabNotShown", defaultValue: "The tab is not on screen. Show its workspace and select the tab, then retry",
               table: "MiscHandlers", bundle: .module)
    }
    static var browserNeedsREPL: String {
        String(localized: "handlers.screenshot.browserNeedsREPL",
               defaultValue: "A browser page's screenshot for automation comes from the browser REPL, which hides the secrets on the page: browser_repl_eval with page.screenshot()",
               table: "MiscHandlers", bundle: .module)
    }
    static func pageFailed(_ reason: String) -> String {
        String(format: String(localized: "handlers.screenshot.pageFailed", defaultValue: "The page could not be captured off screen (%@)",
                              table: "MiscHandlers", bundle: .module), reason)
    }

    /// The reason for a window capture that gave no image.
    static func reason(_ failure: WindowScreenshotFailure) -> String {
        switch failure {
        case .notOnScreen: notOnScreen
        case .minimized: minimized
        case .blank: blank
        }
    }
}
