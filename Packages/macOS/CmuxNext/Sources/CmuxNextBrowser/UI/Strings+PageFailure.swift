import Foundation

/// Sad tab and "Page unresponsive" strings.
extension Strings {
    static func pageGoneTitle(_ reason: BrowserProcessExit.Reason) -> String {
        switch reason {
        case .crashed:
            String(localized: "browser.pageGone.title.crashed", defaultValue: "This page crashed", bundle: .l10n)
        case .killed:
            String(localized: "browser.pageGone.title.killed", defaultValue: "This page was stopped", bundle: .l10n)
        case .outOfMemory:
            String(localized: "browser.pageGone.title.outOfMemory", defaultValue: "This page ran out of memory", bundle: .l10n)
        case .launchFailed:
            String(localized: "browser.pageGone.title.launchFailed", defaultValue: "This page couldn’t start", bundle: .l10n)
        case .integrityFailure, .abnormal:
            String(localized: "browser.pageGone.title.other", defaultValue: "Something went wrong with this page", bundle: .l10n)
        }
    }

    static func pageGoneMessage(_ reason: BrowserProcessExit.Reason) -> String {
        String(localized: "browser.pageGone.message", defaultValue: "Other tabs are not affected. Reload to open the page again.", bundle: .l10n)
    }

    /// Chrome's sad tab title (IDS_SAD_TAB_TITLE) for a Chromium tab.
    static var pageGoneChromiumTitle: String {
        String(localized: "browser.pageGone.chromium.title", defaultValue: "Aw, Snap!", bundle: .l10n)
    }

    /// Chrome's sad tab message (IDS_SAD_TAB_MESSAGE) for a Chromium tab.
    static var pageGoneChromiumMessage: String {
        String(localized: "browser.pageGone.chromium.message",
               defaultValue: "Something went wrong while displaying this webpage.", bundle: .l10n)
    }

    static func pageGoneErrorCode(_ code: String) -> String {
        String(format: String(localized: "browser.pageGone.errorCode", defaultValue: "Error code: %@", bundle: .l10n), code)
    }

    static var pageGoneReload: String {
        String(localized: "browser.pageGone.reload", defaultValue: "Reload", bundle: .l10n)
    }

    static var pageUnresponsiveTitle: String {
        String(localized: "browser.pageUnresponsive.title", defaultValue: "Page unresponsive", bundle: .l10n)
    }

    static var pageUnresponsiveMessage: String {
        String(localized: "browser.pageUnresponsive.message", defaultValue: "You can wait for it to respond or exit the page.", bundle: .l10n)
    }

    static var pageUnresponsiveWait: String {
        String(localized: "browser.pageUnresponsive.wait", defaultValue: "Wait", bundle: .l10n)
    }

    static var pageUnresponsiveExit: String {
        String(localized: "browser.pageUnresponsive.exit", defaultValue: "Exit page", bundle: .l10n)
    }

    static func extensionsCrashed(_ names: [String]) -> String {
        String(format: String(localized: "browser.extensions.crashed", defaultValue: "Crashed: %@. Click to reload.", bundle: .l10n),
               names.joined(separator: ", "))
    }
}
