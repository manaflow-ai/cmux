import CmuxNextDesign
import Foundation

/// HTTP basic, digest and NTLM sign-in for browser tabs (R96): a cmux dialog
/// that blocks only the asking tab and names the server. Engine-neutral: the
/// WebKit tab uses it (before, WebKit's default handling had no UI and
/// sign-in failed silently), and the CEF auth handler is to use it too.
/// Cancel lets the server's 401 page load. Nothing is remembered past this
/// app session unless the user checks "Remember password"; then the
/// credential is permanent (WebKit keeps it in the login Keychain).
enum BrowserHTTPAuth {
    static let methods: Set<String> = [NSURLAuthenticationMethodHTTPBasic, NSURLAuthenticationMethodHTTPDigest,
                                       NSURLAuthenticationMethodNTLM, NSURLAuthenticationMethodDefault]

    static func asksUser(_ method: String) -> Bool { methods.contains(method) }

    static func spec(host: String, realm: String?, isSecure: Bool, failedBefore: Bool, user: String?) -> CmuxDialogSpec {
        var lines = [String(localized: "browser.auth.message", defaultValue: "The server asks for a user name and password.", bundle: .module)]
        if let realm, !realm.isEmpty {
            lines.append(String(format: String(localized: "browser.auth.realm", defaultValue: "Realm: %@", bundle: .module), realm))
        }
        if !isSecure {
            lines.append(String(localized: "browser.auth.insecure", defaultValue: "Your user name and password are sent without encryption.", bundle: .module))
        }
        if failedBefore {
            lines.append(String(localized: "browser.auth.failed", defaultValue: "The user name or password is not correct.", bundle: .module))
        }
        return CmuxDialogSpec(
            title: String(format: String(localized: "browser.auth.title", defaultValue: "Sign in to %@", bundle: .module), host),
            lines: lines,
            origin: host,
            fields: [
                .text("user", initial: user ?? "", label: String(localized: "browser.auth.user", defaultValue: "User Name", bundle: .module)),
                .text(id: "password", label: String(localized: "browser.auth.password", defaultValue: "Password", bundle: .module),
                      initial: "", placeholder: nil, secure: true),
                .check(id: "remember", title: Strings.authRemember, on: false),
            ],
            buttons: [.cancel(Strings.cancel),
                      CmuxDialogButton(id: "sign-in", title: String(localized: "browser.auth.signIn", defaultValue: "Sign In", bundle: .module), role: .default)],
            identifier: "browser.dialog.httpAuth")
    }

    /// The URL credential for a prompt response; nil unless it carries one.
    static func urlCredential(for response: BrowserPromptResponse) -> URLCredential? {
        guard case .credentials(let user, let password, let remember) = response else { return nil }
        return URLCredential(user: user, password: password, persistence: remember ? .permanent : .forSession)
    }

    /// The credential for an answer; nil when the user cancelled.
    static func credential(for answer: CmuxDialogAnswer) -> URLCredential? {
        guard answer.button == "sign-in" else { return nil }
        return URLCredential(user: answer.text("user") ?? "", password: answer.text("password") ?? "",
                             persistence: answer.isOn("remember") ? .permanent : .forSession)
    }
}
