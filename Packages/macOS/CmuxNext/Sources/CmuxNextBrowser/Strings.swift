import Foundation

/// Localized strings for the browser module. Keys live in
/// Resources/Localizable.xcstrings (en, ja).
nonisolated enum Strings {
    // Toolbar
    static var back: String { String(localized: "browser.toolbar.back", defaultValue: "Back", bundle: .module) }
    static var forward: String { String(localized: "browser.toolbar.forward", defaultValue: "Forward", bundle: .module) }
    static var reload: String { String(localized: "browser.toolbar.reload", defaultValue: "Reload This Page", bundle: .module) }
    static var stop: String { String(localized: "browser.toolbar.stop", defaultValue: "Stop Loading", bundle: .module) }
    static var extensions: String { String(localized: "browser.toolbar.extensions", defaultValue: "Extensions", bundle: .module) }

    // Address bar
    static func searchWith(engine: String) -> String {
        String(localized: "browser.suggestion.searchWith", defaultValue: "\(engine) Search", bundle: .module)
    }
    /// Chromium's `IDS_OMNIBOX_EMPTY_HINT`, as Helium shows it.
    static var omnibarPlaceholder: String {
        String(localized: "browser.omnibar.placeholder", defaultValue: "Search or type URL", bundle: .module)
    }
    static var pasteAndGo: String { String(localized: "browser.omnibar.pasteAndGo", defaultValue: "Paste and Go", bundle: .module) }
    static var pasteAndSearch: String { String(localized: "browser.omnibar.pasteAndSearch", defaultValue: "Paste and Search", bundle: .module) }
    static var newTab: String { String(localized: "browser.tab.new", defaultValue: "New Tab", bundle: .module) }
    static var notSecure: String { String(localized: "browser.address.notSecure", defaultValue: "Not Secure", bundle: .module) }

    // Find
    static var findPlaceholder: String { String(localized: "browser.find.placeholder", defaultValue: "Find in page", bundle: .module) }
    static var findPrevious: String { String(localized: "browser.find.previous", defaultValue: "Previous Match", bundle: .module) }
    static var findNext: String { String(localized: "browser.find.next", defaultValue: "Next Match", bundle: .module) }
    static var findDone: String { String(localized: "browser.find.done", defaultValue: "Done", bundle: .module) }
    static var findNoMatches: String { String(localized: "browser.find.noMatches", defaultValue: "No matches", bundle: .module) }
    static func findPosition(_ index: Int, of count: Int) -> String {
        String(localized: "browser.find.position", defaultValue: "\(index) of \(count)", bundle: .module)
    }
    static func findCount(_ count: Int) -> String {
        String(localized: "browser.find.count", defaultValue: "\(count) matches", bundle: .module)
    }

    // Prompts
    static func permissionCamera(_ origin: String) -> String {
        String(localized: "browser.permission.camera", defaultValue: "\(origin) wants to use your camera.", bundle: .module)
    }
    static func permissionMicrophone(_ origin: String) -> String {
        String(localized: "browser.permission.microphone", defaultValue: "\(origin) wants to use your microphone.", bundle: .module)
    }
    static func permissionCameraAndMicrophone(_ origin: String) -> String {
        String(localized: "browser.permission.cameraAndMicrophone", defaultValue: "\(origin) wants to use your camera and microphone.", bundle: .module)
    }
    static func dialogFrom(_ origin: String) -> String {
        String(localized: "browser.dialog.from", defaultValue: "\(origin) says", bundle: .module)
    }
    static var allow: String { String(localized: "browser.prompt.allow", defaultValue: "Allow", bundle: .module) }
    static var dontAllow: String { String(localized: "browser.prompt.deny", defaultValue: "Don’t Allow", bundle: .module) }
    static var ok: String { String(localized: "browser.prompt.ok", defaultValue: "OK", bundle: .module) }
    static var cancel: String { String(localized: "browser.prompt.cancel", defaultValue: "Cancel", bundle: .module) }

    // Context menu
    static var openLinkInNewTab: String { String(localized: "browser.menu.openLinkInNewTab", defaultValue: "Open Link in New Tab", bundle: .module) }
    static var openImageInNewTab: String { String(localized: "browser.menu.openImageInNewTab", defaultValue: "Open Image in New Tab", bundle: .module) }
    static var openVideoInNewTab: String { String(localized: "browser.menu.openVideoInNewTab", defaultValue: "Open Video in New Tab", bundle: .module) }

    // Errors and engines
    static var cefUnavailable: String {
        String(localized: "browser.engine.cefUnavailable", defaultValue: "The Chromium engine is not available in this build.", bundle: .module)
    }
    static var webContentProcessTerminated: String {
        String(localized: "browser.error.processTerminated", defaultValue: "This page stopped responding. Reload to try again.", bundle: .module)
    }
    static var loadFailedTitle: String {
        String(localized: "browser.error.loadFailed", defaultValue: "Can’t open this page", bundle: .module)
    }
    static var tryAgain: String { String(localized: "browser.error.tryAgain", defaultValue: "Try Again", bundle: .module) }
}
