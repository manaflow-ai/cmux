import CmuxNextSettings
import Foundation

/// `browser.page.fill_login` (`cmux browser <tab|right> fill-login [--submit] [--agent NAME]`,
/// cmux https://github.com/manaflow-ai/cmux/issues/25830): the agent asks the app to fill the login
/// the person saved in the Secure Store for the tab's site, so it signs in without ever seeing the
/// password. Params: `tab`, `agent`, `submit` (then submit the form). A write verb: it takes the
/// tab's lease like `fill`, and on `right` runs only on the agent's own or a handed-over tab.
///
/// Only into an agent-profile tab, only over https, only into a document no agent script ran on,
/// and agent scripts are refused on that document afterwards (``BrowserLoginGuards``). The fill and
/// submit scripts run in cmux's isolated world, so a page-world hook never sees the values.
///
/// Answers `{tab, filled, site, username_filled, password_filled, submitted}`, plus `reason` when
/// nothing was filled: `no_saved_login` (`site` null), `not_agent_tab` (the person's profile),
/// `not_https`, `scripted_page` (an agent script ran on this document: open the page again),
/// `opened_by_page` (another window opened it and could reach in), `page_unavailable` (the page
/// could not be read), `no_login_field`, or `navigated` (the page moved before the fill ran).
/// The answer never holds the username or the password; nothing here logs them, the agent cursor
/// draws the fill as secret with no text, and a page error comes back without its message.
extension BrowserPageService {
    func fillLoginMethods() -> [ControlMethod] {
        let engine = engine
        let logins = logins
        let guards = loginGuards
        return [
            .async("browser.page.fill_login") { call in
                let tab = try Self.tab(call)
                let submit = call.request.params["submit"]?.boolValue == true
                // The person's own profile never gets one, even named by `tab`.
                guard Self.isAgentProfile(tab.browserProfileID) else {
                    return Self.loginAnswer(tab, site: nil, reason: "not_agent_tab")
                }
                let state = try await Self.run(engine, .state, tab)
                let url = (state["url"]?.stringValue).flatMap(URL.init(string:)) ?? tab.url.flatMap(URL.init(string:))
                guard let url, let host = url.host()?.lowercased(), !host.isEmpty,
                      let login = await Self.savedLogin(for: host, in: logins) else {
                    return Self.loginAnswer(tab, site: nil, reason: "no_saved_login")
                }
                guard url.scheme?.lowercased() == "https" else {
                    return Self.loginAnswer(tab, site: login.site, reason: "not_https")
                }
                let probe = await Self.probeDocument(engine, tab)
                guard let document = probe.document else {
                    return Self.loginAnswer(tab, site: login.site, reason: "page_unavailable")
                }
                guard !probe.opener else { return Self.loginAnswer(tab, site: login.site, reason: "opened_by_page") }
                guard await guards.beginFill(tab: tab.id, document: document) else {
                    return Self.loginAnswer(tab, site: login.site, reason: "scripted_page")
                }
                let script = BrowserPageScripts.fillLogin(host: host, document: document, username: login.username, password: login.password)
                let value = try await Self.runLoginScript(engine, script, tab)
                let fields = value["value"] ?? .null
                let username = fields["username"]?.boolValue == true
                let password = fields["password"]?.boolValue == true
                guard username || password else {
                    await guards.forgetFill(tab: tab.id, document: document)
                    return Self.loginAnswer(tab, site: login.site, reason: fields["reason"]?.stringValue ?? "no_login_field")
                }
                var input = BrowserPageAgentInput.from(kind: .type, answer: value, replace: true)
                input.text = nil
                input.secret = true
                await engine.announce(Self.attributed(input, call), tabID: tab.id)
                var submitted = false
                if submit {
                    // A second script, a later task: the page's framework has taken the values.
                    let submitScript = BrowserPageScripts.submitLogin(host: host, document: document)
                    submitted = try await Self.runLoginScript(engine, submitScript, tab)["value"]?.boolValue == true
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

    /// The tab's current document as cmux's isolated world names it (``BrowserPageScripts/documentProbe``);
    /// a nil document when the page cannot be read.
    static func probeDocument(_ engine: any BrowserPageEngine, _ tab: Tab) async -> (document: String?, opener: Bool) {
        guard let answer = try? await run(engine, .evaluateIsolated(BrowserPageScripts.documentProbe), tab)["value"] else {
            return (nil, false)
        }
        let document = answer["document"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        return (document, answer["opener"]?.boolValue == true)
    }

    /// Before an agent's own script (`eval`, `wait --function`): refused with `login_filled` on a
    /// document holding a filled login; else that document takes no login afterwards.
    static func beginAgentScript(_ engine: any BrowserPageEngine, _ tab: Tab, _ guards: BrowserLoginGuards) async throws {
        let document = await probeDocument(engine, tab).document
        guard await guards.beginScript(tab: tab.id, document: document) else {
            throw ControlError(code: "login_filled",
                               message: ControlStrings.text("control.error.loginFilled",
                                                            "This page holds a filled sign-in; open another page first"),
                               data: ["tab": .string(tab.id)])
        }
    }

    /// After an agent's own script: the document it ended on (it may have navigated) takes no login.
    static func endAgentScript(_ engine: any BrowserPageEngine, _ tab: Tab, _ guards: BrowserLoginGuards) async {
        await guards.markScripted(tab: tab.id, document: probeDocument(engine, tab).document)
    }

    /// `body`, an agent's own script, between ``beginAgentScript(_:_:_:)`` and
    /// ``endAgentScript(_:_:_:)``; with no guards (not an agent script) only `body`.
    static func guardedAgentScript(_ engine: any BrowserPageEngine, _ tab: Tab, _ guards: BrowserLoginGuards?,
                                   _ body: () async throws -> JSONValue) async throws -> JSONValue {
        guard let guards else { return try await body() }
        try await beginAgentScript(engine, tab, guards)
        let value: JSONValue
        do {
            value = try await body()
        } catch {
            await endAgentScript(engine, tab, guards)
            throw error
        }
        await endAgentScript(engine, tab, guards)
        return value
    }

    /// Runs a login script in cmux's isolated world; a failure keeps its code but not its message,
    /// which a page error could fill with whatever the script held.
    private static func runLoginScript(_ engine: any BrowserPageEngine, _ script: String, _ tab: Tab) async throws -> JSONValue {
        let answer: JSONValue
        do {
            answer = try await run(engine, .evaluateIsolated(script), tab)["value"] ?? .null
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
        result["site"] = site.map { JSONValue.string($0) } ?? .null
        result["username_filled"] = .bool(username)
        result["password_filled"] = .bool(password)
        result["submitted"] = .bool(submitted)
        if let reason { result["reason"] = .string(reason) }
        return .object(result)
    }
}
