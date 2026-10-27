import CmuxNextDaemon
import CmuxNextSettings
import Foundation

/// `browser.page.fill_login` (`cmux browser <tab|right> fill-login [--submit] [--agent NAME]`,
/// cmux https://github.com/manaflow-ai/cmux/issues/25830): the agent asks the app to fill the login
/// the person saved in the Secure Store for the tab's site, so it signs in without ever seeing the
/// password. Params: `tab`, `agent`, `submit` (then submit the form). A write verb: it takes the
/// tab's lease like `fill`, and on `right` runs only on the agent's own or a handed-over tab.
///
/// Answers `{tab, filled, site, username_filled, password_filled, submitted}`, plus `reason` when
/// nothing was filled: `no_saved_login` (`site` null), `not_https` (a login is only filled into an
/// https page), `no_login_field`, or `navigated` (the page left the host before the fill ran). The
/// answer never holds the username or the password; nothing here logs them, the agent cursor draws
/// the fill as secret with no text, and a page error comes back without its message.
extension BrowserPageService {
    func fillLoginMethods() -> [ControlMethod] {
        let engine = engine
        let logins = logins
        return [
            .async("browser.page.fill_login") { call in
                let tab = try Self.tab(call)
                let submit = call.request.params["submit"]?.boolValue == true
                let state = try await Self.run(engine, .state, tab)
                let url = (state["url"]?.stringValue).flatMap(URL.init(string:)) ?? tab.url.flatMap(URL.init(string:))
                guard let url, let host = url.host()?.lowercased(), !host.isEmpty,
                      let login = await Self.savedLogin(for: host, in: logins) else {
                    return Self.loginAnswer(tab, site: nil, reason: "no_saved_login")
                }
                guard url.scheme?.lowercased() == "https" else {
                    return Self.loginAnswer(tab, site: login.site, reason: "not_https")
                }
                let script = BrowserPageScripts.fillLogin(host: host, username: login.username, password: login.password)
                let value = try await Self.runLoginScript(engine, script, tab)
                let fields = value["value"] ?? .null
                let username = fields["username"]?.boolValue == true
                let password = fields["password"]?.boolValue == true
                guard username || password else {
                    return Self.loginAnswer(tab, site: login.site, reason: fields["reason"]?.stringValue ?? "no_login_field")
                }
                var input = BrowserPageAgentInput.from(kind: .type, answer: value, replace: true)
                input.text = nil
                input.secret = true
                await engine.announce(Self.attributed(input, call), tabID: tab.id)
                var submitted = false
                if submit {
                    // A second script, a later task: the page's framework has taken the values.
                    submitted = try await Self.runLoginScript(engine, BrowserPageScripts.submitLogin, tab)["value"]?.boolValue == true
                }
                return Self.loginAnswer(tab, site: login.site, username: username, password: password, submitted: submitted)
            },
        ]
    }

    /// The saved login for `host`; the store matches the site or a parent domain of it
    /// (`www.linkedin.com` uses `linkedin.com`).
    static func savedLogin(for host: String, in logins: BrowserPageLogins?) async -> BrowserPageLogin? {
        guard let logins else { return nil }
        return await logins(host)
    }

    /// The app's lookup: ``ChiefSecureStore``, the login keychain, read off every actor since its
    /// calls block.
    public static let secureStoreLogins: BrowserPageLogins = { host in
        await Task.detached(priority: .userInitiated) {
            ChiefSecureStore().credential(forHost: host).map { BrowserPageLogin(site: $0.site, username: $0.username, password: $0.password) }
        }.value
    }

    /// Runs a login script; a failure keeps its code but not its message, which a page error could
    /// fill with whatever the script held.
    private static func runLoginScript(_ engine: any BrowserPageEngine, _ script: String, _ tab: Tab) async throws -> JSONValue {
        let answer: JSONValue
        do {
            answer = try await run(engine, .evaluate(script), tab)["value"] ?? .null
        } catch let error as ControlError where error.code == "js_error" || error.code == "app_error" {
            throw ControlError(code: error.code, message: ControlStrings.text("control.error.fillLoginFailed",
                                                                              "The page did not take the saved login"))
        }
        return answer
    }

    /// The answer: which fields were filled, never what.
    static func loginAnswer(_ tab: Tab, site: String?, username: Bool = false, password: Bool = false, submitted: Bool = false,
                            reason: String? = nil) -> JSONValue {
        var result = base(tab)
        result["filled"] = .bool(username || password)
        result["site"] = site.map(JSONValue.string) ?? .null
        result["username_filled"] = .bool(username)
        result["password_filled"] = .bool(password)
        result["submitted"] = .bool(submitted)
        if let reason { result["reason"] = .string(reason) }
        return .object(result)
    }
}
