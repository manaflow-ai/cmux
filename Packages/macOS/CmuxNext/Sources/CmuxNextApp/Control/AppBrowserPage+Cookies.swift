import CmuxNextBrowser
import CmuxNextControl
import CmuxNextSettings
import Foundation

/// `browser.page.cookies.*` on the tab's engine store.
extension AppBrowserPage {
    static func cookies(_ page: any BrowserTab, _ request: BrowserPageCookieRequest) async throws -> JSONValue {
        do {
            switch request {
            case .list:
                return ["cookies": .array(try await page.cookies().map { pageCookie($0).json })]
            case .set(let cookies):
                for cookie in cookies { try await page.setCookie(browserCookie(cookie)) }
            case .delete(let cookies):
                try await page.deleteCookies(cookies.map(browserCookie))
            }
            return [:]
        } catch let error as ControlError {
            throw error
        } catch BrowserTabError.unsupported("cookies") {
            // A hibernated or still-starting tab has no engine store yet.
            throw ControlError(code: "unavailable", message: "The browser page is not running; show the tab and retry")
        } catch {
            throw ControlError(code: "app_error", message: String(describing: error))
        }
    }

    static func pageCookie(_ cookie: BrowserCookie) -> BrowserPageCookie {
        BrowserPageCookie(name: cookie.name, value: cookie.value, domain: cookie.domain, path: cookie.path,
                          expires: cookie.expires?.timeIntervalSince1970, secure: cookie.secure, httpOnly: cookie.httpOnly)
    }

    static func browserCookie(_ cookie: BrowserPageCookie) -> BrowserCookie {
        BrowserCookie(name: cookie.name, value: cookie.value, domain: cookie.domain, path: cookie.path,
                      expires: cookie.expires.map(Date.init(timeIntervalSince1970:)), secure: cookie.secure, httpOnly: cookie.httpOnly)
    }
}
