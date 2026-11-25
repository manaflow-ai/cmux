import Foundation

/// A server's 401 on a Chromium tab (AUTH_PROMPT, `CEFShim/src/shim_client.mm`): the same sign-in question as
/// WebKit's (`BrowserHTTPAuth`), a cmux dialog on this tab that names the server. Sign In continues with the
/// credential; Cancel lets the server's 401 page load. Chromium's own sign-in dialog needs a toolbar cmux never
/// shows, so before this a Chromium tab on a Basic-auth site never got past the challenge (Leo, 2026-11-24, after
/// cmux#53071: "this is fixable. I feel like there is similar thing maybe with probably logins and redirects and
/// popups and whatnot", ask-2d244f2b2e).
struct CEFHTTPAuthPrompts {
    let tab: CEFTab

    func ask(token: Int32, host: String, realm: String, isSecure: Bool) {
        let runtime = tab.runtime
        tab.enqueuePrompt(.credentials(host: host, realm: realm.isEmpty ? nil : realm), origin: host) { response in
            switch response {
            case .credentials(let user, let password, _): runtime.authContinue(token, user: user, password: password)
            default: runtime.authContinue(token, user: nil)
            }
        }
    }
}
