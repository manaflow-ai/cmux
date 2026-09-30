import Foundation

/// Sad tab and "Page unresponsive" strings.
extension Strings {
    static func pageGoneTitle(_ reason: BrowserProcessExit.Reason) -> String {
        switch reason {
        case .crashed:
            String(localized: "browser.pageGone.title.crashed", defaultValue: "This page crashed", bundle: .module)
        case .killed:
            String(localized: "browser.pageGone.title.killed", defaultValue: "This page was stopped", bundle: .module)
        case .outOfMemory:
            String(localized: "browser.pageGone.title.outOfMemory", defaultValue: "This page ran out of memory", bundle: .module)
        case .launchFailed:
            String(localized: "browser.pageGone.title.launchFailed", defaultValue: "This page couldn’t start", bundle: .module)
        case .integrityFailure, .abnormal:
            String(localized: "browser.pageGone.title.other", defaultValue: "Something went wrong with this page", bundle: .module)
        }
    }

    static func pageGoneMessage(_ reason: BrowserProcessExit.Reason) -> String {
        String(localized: "browser.pageGone.message", defaultValue: "Other tabs are not affected. Reload to open the page again.", bundle: .module)
    }

    static func pageGoneErrorCode(_ code: String) -> String {
        String(format: String(localized: "browser.pageGone.errorCode", defaultValue: "Error code: %@", bundle: .module), code)
    }

    static var pageGoneReload: String {
        String(localized: "browser.pageGone.reload", defaultValue: "Reload", bundle: .module)
    }

    static var pageUnresponsiveTitle: String {
        String(localized: "browser.pageUnresponsive.title", defaultValue: "Page unresponsive", bundle: .module)
    }

    static var pageUnresponsiveMessage: String {
        String(localized: "browser.pageUnresponsive.message", defaultValue: "You can wait for it to respond or exit the page.", bundle: .module)
    }

    static var pageUnresponsiveWait: String {
        String(localized: "browser.pageUnresponsive.wait", defaultValue: "Wait", bundle: .module)
    }

    static var pageUnresponsiveExit: String {
        String(localized: "browser.pageUnresponsive.exit", defaultValue: "Exit page", bundle: .module)
    }
}
