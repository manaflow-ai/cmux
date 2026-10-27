import CmuxNextSettings
import Foundation

/// `browser.page.fill_login` (`cmux browser <tab|right> fill-login [--submit] [--agent NAME]`,
/// cmux https://github.com/manaflow-ai/cmux/issues/25830): the agent asks the app to fill the login
/// the person saved in the Secure Store for the tab's site, so it signs in without ever seeing the
/// password. Params: `tab`, `agent`, `submit` (then submit the form). A write verb: it takes the
/// tab's lease like `fill`, and on `right` runs only on the agent's own or a handed-over tab.
///
/// Behind `browser.agentSecureStoreFill` (off by default). Only into an agent-profile tab, only
/// over https, only on a site (origin) no agent code ever ran on, and agent code on that site is
/// refused from then on (``BrowserLoginGuards``). The fill and submit scripts run in cmux's
/// isolated world, so a page-world hook never sees the values.
///
/// Answers `{tab, filled, site, username_filled, password_filled, submitted}`, plus `reason` when
/// nothing was filled: `disabled` (the setting is off), `no_saved_login` (`site` null),
/// `not_agent_tab` (the person's profile), `not_https`, `scripted_origin` (agent code ran on this
/// site, or the tab had a raw DevTools relay), `raw_devtools_attached` (a raw DevTools relay is
/// attached to a tab of the profile), `opened_by_page` (a page opened the tab and could
/// reach in), `guard_unreadable` / `guard_unsaved` (the guard file cannot be read or saved),
/// `page_unavailable` (the page's origin could not be read), `no_login_field`, or `navigated`
/// (the page moved before the fill ran). The answer never
/// holds the username or the password; nothing here logs them, the agent cursor draws the fill as
/// secret with no text, and a page error comes back without its message.
extension BrowserPageService {
    func fillLoginMethods() -> [ControlMethod] {
        let engine = engine
        let logins = logins
        let guards = loginGuards
        let enabled = secureStoreFillEnabled
        return [
            .async("browser.page.fill_login") { call in
                let tab = try Self.tab(call)
                let submit = call.request.params["submit"]?.boolValue == true
                // `browser.agentSecureStoreFill`, off by default: no fill at all.
                guard await enabled() else { return Self.loginAnswer(tab, site: nil, reason: "disabled") }
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
                let page = await Self.pageOrigin(engine, tab, url: url.absoluteString)
                guard let probed = page.probed, probed != "null", let origins = page.origins else {
                    return Self.loginAnswer(tab, site: login.site, reason: "page_unavailable")
                }
                guard !page.opener else { return Self.loginAnswer(tab, site: login.site, reason: "opened_by_page") }
                let fill = await guards.beginFill(tab: tab.id, profile: tab.browserProfileID, origins: origins)
                guard fill.admission == .admitted else { return Self.loginAnswer(tab, site: login.site, reason: fill.admission.rawValue) }
                let script = BrowserPageScripts.fillLogin(host: host, origin: probed, username: login.username, password: login.password)
                let value = try await Self.runLoginScript(engine, script, tab)
                let fields = value["value"] ?? .null
                let username = fields["username"]?.boolValue == true
                let password = fields["password"]?.boolValue == true
                guard username || password else {
                    // Only the marks this fill added: an earlier fill's stay.
                    await guards.forgetFill(fill.added)
                    return Self.loginAnswer(tab, site: login.site, reason: fields["reason"]?.stringValue ?? "no_login_field")
                }
                var input = BrowserPageAgentInput.from(kind: .type, answer: value, replace: true)
                input.text = nil
                input.secret = true
                await engine.announce(Self.attributed(input, call), tabID: tab.id)
                var submitted = false
                if submit {
                    // A second script, a later task: the page's framework has taken the values.
                    let submitScript = BrowserPageScripts.submitLogin(host: host, origin: probed)
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

    /// `scheme://host[:port]` of a web URL as `location.origin` writes it (default port left
    /// out); nil for a page with no site (about:, data:, a file).
    static func webOrigin(_ url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host()?.lowercased(), !host.isEmpty else { return nil }
        let shown = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        guard let port = url.port, port != (scheme == "https" ? 443 : 80) else { return "\(scheme)://\(shown)" }
        return "\(scheme)://\(shown):\(port)"
    }

    /// The tab's page origins for ``BrowserLoginGuards``: the engine's URL and the isolated
    /// world's `location.origin` (``BrowserPageScripts/originProbe``). `origins` is nil when
    /// either cannot be read, empty for a page with no site; `probed` is what the probe read
    /// (`"null"` for an opaque page), `opener` whether another window opened it.
    static func pageOrigin(_ engine: any BrowserPageEngine, _ tab: Tab,
                           url known: String? = nil) async -> (origins: [String]?, probed: String?, opener: Bool) {
        let raw: String?
        if let known {
            raw = known
        } else {
            raw = (try? await run(engine, .state, tab))?["url"]?.stringValue ?? tab.url
        }
        let answer = try? await run(engine, .evaluateIsolated(BrowserPageScripts.originProbe), tab)["value"]
        let probed = answer?["origin"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        let opener = answer?["opener"]?.boolValue == true
        guard let raw, let url = URL(string: raw), let probed else { return (nil, probed, opener) }
        var origins: [String] = []
        if let engineOrigin = webOrigin(url) { origins.append(engineOrigin) }
        if probed != "null", !origins.contains(probed) { origins.append(probed) }
        return (origins, probed, opener)
    }

    /// Before an agent's own script (`eval`, `wait --function`): refused with `login_filled` on a
    /// site holding a filled login (or, when the page's origin cannot be read, while this profile
    /// holds any); else the site takes no login from then on.
    static func beginAgentScript(_ engine: any BrowserPageEngine, _ tab: Tab, _ guards: BrowserLoginGuards) async throws {
        let page = await pageOrigin(engine, tab)
        guard await guards.beginScript(profile: tab.browserProfileID, origins: page.origins) else {
            throw ControlError(code: "login_filled",
                               message: ControlStrings.text("control.error.loginFilled",
                                                            "This site holds a filled sign-in; agent scripts cannot run on it"),
                               data: ["tab": .string(tab.id)])
        }
    }

    /// Before a capture (a screenshot): refused with `login_filled` on a site holding a filled
    /// sign-in (or, its origin unknown, while the profile holds any). The fill's observer empties a
    /// revealed password, but a capture does not rely on it.
    static func refuseCaptureOfFilledSite(_ engine: any BrowserPageEngine, _ tab: Tab, _ guards: BrowserLoginGuards) async throws {
        let page = await pageOrigin(engine, tab)
        guard await guards.mayCapture(profile: tab.browserProfileID, origins: page.origins) else {
            throw ControlError(code: "login_filled",
                               message: ControlStrings.text("control.error.loginFilled",
                                                            "This site holds a filled sign-in; agent scripts cannot run on it"),
                               data: ["tab": .string(tab.id)])
        }
    }

    /// After an agent's own script: the site it ended on (it may have navigated) takes no login.
    static func endAgentScript(_ engine: any BrowserPageEngine, _ tab: Tab, _ guards: BrowserLoginGuards) async {
        await guards.markScripted(profile: tab.browserProfileID, origins: pageOrigin(engine, tab).origins)
    }

    /// `body`, the agent's own page code (a script, a storage or cookie write), between
    /// ``beginAgentScript(_:_:_:)`` and ``endAgentScript(_:_:_:)``; with no guards only `body`.
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
