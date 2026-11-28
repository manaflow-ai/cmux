import Foundation

/// Sad tab and "Page unresponsive" strings.
extension Strings {
    static func pageGoneTitle(_ reason: BrowserProcessExit.Reason) -> String {
        switch reason {
        case .crashed:
            String(localized: "browser.pageGone.title.crashed", defaultValue: "This page crashed", bundle: .localizedModule)
        case .killed:
            String(localized: "browser.pageGone.title.killed", defaultValue: "This page was stopped", bundle: .localizedModule)
        case .outOfMemory:
            String(localized: "browser.pageGone.title.outOfMemory", defaultValue: "This page ran out of memory", bundle: .localizedModule)
        case .launchFailed:
            String(localized: "browser.pageGone.title.launchFailed", defaultValue: "This page couldn’t start", bundle: .localizedModule)
        case .integrityFailure, .abnormal:
            String(localized: "browser.pageGone.title.other", defaultValue: "Something went wrong with this page", bundle: .localizedModule)
        }
    }

    static func pageGoneMessage(_ reason: BrowserProcessExit.Reason) -> String {
        // retry-prompt-ok: the sad tab: a crashed or ended page reloads on the person's click (crash loop, or their Exit); a memory end reloads once by itself
        String(localized: "browser.pageGone.message", defaultValue: "Other tabs are not affected. Reload to open the page again.", bundle: .localizedModule)
    }

    /// Chrome's sad tab title (IDS_SAD_TAB_TITLE) for a Chromium tab.
    static var pageGoneChromiumTitle: String {
        String(localized: "browser.pageGone.chromium.title", defaultValue: "Aw, Snap!", bundle: .localizedModule)
    }

    /// Chrome's sad tab message (IDS_SAD_TAB_MESSAGE) for a Chromium tab.
    static var pageGoneChromiumMessage: String {
        String(localized: "browser.pageGone.chromium.message",
               defaultValue: "Something went wrong while displaying this webpage.", bundle: .localizedModule)
    }

    static func pageGoneErrorCode(_ code: String) -> String {
        String(format: String(localized: "browser.pageGone.errorCode", defaultValue: "Error code: %@", bundle: .localizedModule), code)
    }

    static var pageGoneReload: String {
        // retry-prompt-ok: the sad tab's Reload: a crash could loop, an Exit was the person's
        String(localized: "browser.pageGone.reload", defaultValue: "Reload", bundle: .localizedModule)
    }

    static var pageUnresponsiveTitle: String {
        String(localized: "browser.pageUnresponsive.title", defaultValue: "Page unresponsive", bundle: .localizedModule)
    }

    static var pageUnresponsiveMessage: String {
        String(localized: "browser.pageUnresponsive.message", defaultValue: "You can wait for it to respond or exit the page.", bundle: .localizedModule)
    }

    static var pageUnresponsiveWait: String {
        String(localized: "browser.pageUnresponsive.wait", defaultValue: "Wait", bundle: .localizedModule)
    }

    static var pageUnresponsiveExit: String {
        String(localized: "browser.pageUnresponsive.exit", defaultValue: "Exit page", bundle: .localizedModule)
    }

    static func extensionsCrashed(_ names: [String]) -> String {
        // retry-prompt-ok: a crashed extension reloads on a click: reloading by itself could loop a crashing process
        String(format: String(localized: "browser.extensions.crashed", defaultValue: "Crashed: %@. Click to reload.", bundle: .localizedModule),
               names.joined(separator: ", "))
    }
}
