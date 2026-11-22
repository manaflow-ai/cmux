public import CmuxNextSettings
import Foundation

/// `browser.page.*`: page commands for the browser tabs the app hosts,
/// addressed by public tab id (`params.tab`, any unique prefix) or, without
/// one, the focused tab. The `cmux browser` CLI sends a `tab_…` selector here
/// and a `browser_…` selector (a daemon-owned browser) to the daemon.
public struct BrowserPageService: Sendable {
    let engine: any BrowserPageEngine
    /// Which agent drives which tab: `browser.page.right` and every write verb
    /// that names an `agent` (``leasing(_:)``).
    let leases: BrowserTabLeases
    /// The passkey hand-off (`browser.page.passkey`); nil serves no such method.
    let passkeys: BrowserPasskeyRequests?
    /// Lists a tab in a second pane (`browser.page.mirror`, and the Home mirror of a tab an
    /// agent starts driving); nil (tests, hosts without strips) mirrors nothing.
    let mirrors: (any BrowserTabMirrorHost)?
    /// `browser.agentMouse.*` as it is now, read per click.
    let agentMouse: @Sendable () async -> AgentMouseSetting.Value
    /// Test-only seam for the direct pixel-capture contract. Production leaves this false because
    /// only cmux-browser-host has the cross-session secret masker required before agent captures.
    let allowsUnsafeCapture: Bool

    /// - Parameters:
    ///   - engine: runs page operations in the app's tabs.
    ///   - passkeys: the passkey hand-off the app's banners answer; nil (tests, hosts without
    ///     banners) leaves `browser.page.passkey` unserved.
    ///   - agentMouse: the person's `browser.agentMouse.*` settings, read per click; nil
    ///     (hosts without settings) uses the defaults, human motion with a 350 ms cap.
    ///   - mirrors: lists a tab in a second pane (``BrowserTabMirrorHost``); nil serves
    ///     `browser.page.mirror` as unavailable and mirrors no agent tab into Home.
    public init(engine: any BrowserPageEngine, passkeys: BrowserPasskeyRequests? = nil,
                agentMouse: (@Sendable () async -> AgentMouseSetting.Value)? = nil,
                mirrors: (any BrowserTabMirrorHost)? = nil) {
        self.init(engine: engine, leases: BrowserTabLeases(), passkeys: passkeys, agentMouse: agentMouse,
                  allowsUnsafeCapture: false, mirrors: mirrors)
    }

    init(engine: any BrowserPageEngine, leases: BrowserTabLeases, passkeys: BrowserPasskeyRequests? = nil,
         agentMouse: (@Sendable () async -> AgentMouseSetting.Value)? = nil, allowsUnsafeCapture: Bool = false,
         mirrors: (any BrowserTabMirrorHost)? = nil) {
        self.engine = engine
        self.leases = leases
        self.passkeys = passkeys
        self.mirrors = mirrors
        self.agentMouse = agentMouse ?? { AgentMouseSetting.fallback }
        self.allowsUnsafeCapture = allowsUnsafeCapture
    }

    public func install(on router: ControlRouter) {
        let engine = engine
        let leases = leases
        let register: ([ControlMethod]) -> Void = { router.register($0.map { Self.intending(self.leasing($0)) }) }
        func page(_ name: String, _ operation: @escaping @Sendable (ControlCall) throws -> BrowserPageOperation) -> ControlMethod {
            .async("browser.page.\(name)") { call in
                let tab = try Self.tab(call)
                _ = try await Self.run(engine, try operation(call), tab)
                return .object(Self.base(tab))
            }
        }
        register([
            page("navigate") { .navigate(try Self.string($0, "url")) },
            page("back") { _ in .back },
            page("forward") { _ in .forward },
            page("reload") { _ in .reload },
            .async("browser.page.state") { call in
                let tab = try Self.tab(call)
                let state = try await Self.run(engine, .state, tab)
                var result: [String: JSONValue] = Self.base(tab)
                result["url"] = state["url"] ?? .string(tab.url ?? "about:blank")
                result["title"] = state["title"] ?? ""
                result["profile"] = .string(tab.browserProfileID ?? "default")
                // Who drives this tab now (#24413), so an agent sees it before it acts.
                if let driver = await leases.holder(of: tab.id) { result["driver"] = .string(driver) }
                return .object(result)
            },
            .async("browser.page.eval") { call in
                let script = try Self.string(call, "script")
                let tab = try Self.tab(call)
                let value: JSONValue
                do {
                    // Objects WebKit cannot return (DOMRect, Map, …) go through toJSON.
                    value = try await Self.run(engine, .evaluate(BrowserPageScripts.jsonSafe(script)), tab)
                } catch let error as ControlError where error.code == "js_error" && error.message.contains("SyntaxError") {
                    // The wrapper reports what the script throws, so this is a
                    // parse failure: nothing ran. Statements, not an expression.
                    value = try await Self.run(engine, .evaluate(script), tab)
                }
                if let thrown = value["value"]?[BrowserPageScripts.thrownKey]?.stringValue {
                    throw ControlError(code: "js_error", message: thrown)
                }
                var result: [String: JSONValue] = Self.base(tab)
                result["value"] = value["value"] ?? .null
                return .object(result)
            },
            .async("browser.page.snapshot") { call in
                let tab = try Self.tab(call)
                let params = call.request.params
                let script = BrowserPageScripts.snapshot(
                    selector: params["selector"]?.stringValue,
                    maxDepth: params["max_depth"]?.intValue ?? 12,
                    interactiveOnly: params["interactive"]?.boolValue == true
                )
                let value = try await Self.run(engine, .evaluate(script), tab)["value"] ?? .null
                if let error = value["error"]?.stringValue {
                    throw ControlError(code: "not_found", message: error)
                }
                var result: [String: JSONValue] = Self.base(tab)
                for key in ["snapshot", "title", "url", "ready_state", "refs", "text"] { result[key] = value[key] ?? .null }
                return .object(result)
            },
            element("click", BrowserPageScripts.click, engine: engine),
            element("fill", BrowserPageScripts.fill, engine: engine),
            element("type", BrowserPageScripts.type, engine: engine),
            element("focus", BrowserPageScripts.focus, engine: engine),
            element("text", BrowserPageScripts.text, engine: engine),
            element("value", BrowserPageScripts.value, engine: engine),
        ])
        register(waitAndCaptureMethods())
        register(tabMethods(router: router))
        router.register([rightMethod(router: router)])
        register(passkeyMethods())
        register(inputMethods())
        register(rawInputMethods())
        register(browserUseMethods())
        register(cookieAndStorageMethods())
        register([mirrorMethod()])
    }

    /// `method`, telling the engine while it runs whether the call only reads its page (``BrowserPageIntent``).
    static func intending(_ method: ControlMethod) -> ControlMethod {
        guard method.name.hasPrefix("browser.page.") else { return method }
        return method.wrappingAsync { call, body in
            // concurrency-allow: the async overload of withValue binds inside the handler's task (always current in an
            // async function), never in the thread's fallback storage that cx-bpcj is about.
            try await BrowserPageIntent.$current.withValue(BrowserPageIntent.of(call)) { try await body(call) }
        }
    }

    /// Selector or snapshot ref (`e3`, `@e3`) actions run as page scripts.
    private func element(_ name: String, _ make: @escaping @Sendable (String, String?) -> String, engine: any BrowserPageEngine) -> ControlMethod {
        let agentMouse = agentMouse
        return .async("browser.page.\(name)") { call in
            let selector = try Self.string(call, "selector")
            let tab = try Self.tab(call)
            let text = call.request.params["text"]?.stringValue
            // `cmux keys fill`: the text is a stored key. It goes only to a site it is for, the
            // agent cursor masks it, and the answer never carries the field's value back.
            let secret = Self.isSecret(call, element: name)
            if secret { try await Self.checkSecretHost(call, tab: tab, engine: engine) }
            let mouse = name == "click" ? await agentMouse() : nil
            let value: JSONValue
            if let mouse, mouse.motion == .human {
                value = try await Self.humanClick(engine, selector: selector, path: HumanPointerPath(mouse), tab: tab)
            } else {
                value = try await Self.run(engine, .evaluate(make(selector, text)), tab)["value"] ?? .null
            }
            if let error = value["error"]?.stringValue {
                throw ControlError(code: "not_found", message: error, data: ["selector": .string(selector)])
            }
            if let input = Self.agentInput(element: name, answer: value, text: text) {
                await engine.announce(Self.attributed(secret ? Self.masked(input) : input, call), tabID: tab.id)
            }
            var result: [String: JSONValue] = Self.base(tab)
            if secret { result["secret"] = .bool(true) } else { result["value"] = value["value"] ?? .null }
            return .object(result)
        }
    }

    /// Whether this `fill` or `type` carries a stored key (`params.secret`, `cmux keys fill`).
    static func isSecret(_ call: ControlCall, element name: String) -> Bool {
        (name == "fill" || name == "type") && call.request.params["secret"]?.boolValue == true
    }

    /// `params.secret_hosts`, lowercased, without a scheme, port, path or trailing dot; empty: any site.
    static func secretHosts(_ call: ControlCall) -> [String] {
        guard case .array(let items)? = call.request.params["secret_hosts"] else { return [] }
        return items.compactMap { item -> String? in
            guard var host = item.stringValue?.trimmingCharacters(in: .whitespaces).lowercased(), !host.isEmpty else { return nil }
            if let rest = host.components(separatedBy: "://").last { host = rest }
            host = String(host.prefix { $0 != "/" && $0 != ":" && $0 != "?" && $0 != "#" })
            while host.hasSuffix(".") { host.removeLast() }
            return host.isEmpty ? nil : host
        }
    }

    /// Whether page `url`'s host is one of `hosts` or under one (`api.example.com` under
    /// `example.com`). A URL with no host (`about:blank`, a file) is under none.
    static func host(of url: String?, isIn hosts: [String]) -> Bool {
        guard let url, var host = URLComponents(string: url)?.host?.lowercased(), !host.isEmpty else { return false }
        while host.hasSuffix(".") { host.removeLast() }
        return hosts.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    /// Refuses a secret fill before any script runs when the tab's page is not on a site the key is
    /// for (`secret_host_mismatch`). The page's own URL wins over the snapshot's, which may lag a
    /// redirect.
    static func checkSecretHost(_ call: ControlCall, tab: Tab, engine: any BrowserPageEngine) async throws {
        let hosts = secretHosts(call)
        guard !hosts.isEmpty else { return }
        let live = try? await engine.run(.state, tabID: tab.id, url: tab.url)["url"]?.stringValue
        let url = live.flatMap { $0.isEmpty ? nil : $0 } ?? tab.url
        guard host(of: url, isIn: hosts) else {
            let shown = url.flatMap { URLComponents(string: $0)?.host } ?? url ?? "about:blank"
            throw ControlError(code: "secret_host_mismatch", message: ControlStrings.format(
                "control.error.secretHostMismatch", "This key is only for %1$@; the tab is on %2$@", hosts.joined(separator: ", "), shown),
                data: ["hosts": .array(hosts.map(JSONValue.string)), "host": .string(shown)])
        }
    }

    /// `input` with its text replaced by as many bullets, marked secret: the agent cursor never
    /// holds a stored key.
    static func masked(_ input: BrowserPageAgentInput) -> BrowserPageAgentInput {
        var copy = input
        copy.secret = true
        copy.text = input.text.map { String(repeating: "•", count: $0.count) }
        return copy
    }

    /// The agent input an element action made, for the agent cursor; nil
    /// for the reads (`text`, `value`).
    static func agentInput(element name: String, answer: JSONValue, text: String?) -> BrowserPageAgentInput? {
        switch name {
        case "click": .from(kind: .click, answer: answer)
        case "focus": .from(kind: .focus, answer: answer)
        case "fill": .from(kind: .type, answer: answer, text: text ?? "", replace: true)
        case "type": .from(kind: .type, answer: answer, text: text ?? "")
        default: nil
        }
    }

    struct Tab: Sendable {
        var id: String
        var url: String?
        var browserProfileID: String?
    }

    /// The tab `params.tab` names (exact id or unique prefix), else the
    /// browser nearest the caller (``BrowserCallerTarget``), else, for a call
    /// that names no caller, the focused tab. It must be a browser tab the app shows.
    static func tab(_ call: ControlCall) throws -> Tab {
        let tabs = call.snapshot.topology.workspaces.flatMap { $0.screens.flatMap { $0.panes.flatMap(\.tabs) } }
        let requested = call.request.params["tab"]?.stringValue?.trimmingCharacters(in: .whitespaces)
        let found: ControlTabInfo
        if let requested, !requested.isEmpty {
            let matches = tabs.filter { $0.id == requested || $0.id.hasPrefix(requested) }
            guard let exact = matches.first(where: { $0.id == requested }) ?? (matches.count == 1 ? matches.first : nil) else {
                throw matches.isEmpty
                    ? ControlError(code: "not_found", message: ControlStrings.format("control.error.pageTabNotFound", "No tab %@", requested))
                    : ControlError(code: "ambiguous", message: ControlStrings.format("control.error.pageTabAmbiguous", "More than one tab starts with %@", requested),
                                   data: ["candidates": .array(matches.map { .string($0.id) })])
            }
            found = exact
        } else if let near = try BrowserCallerTarget.resolve(params: call.request.params, in: call.snapshot.topology) {
            found = near.tab
        } else {
            guard let focused = call.snapshot.topology.focus.tabID, let tab = tabs.first(where: { $0.id == focused }) else {
                throw ControlError(code: "not_found", message: ControlStrings.text("control.error.noFocusedBrowser", "No focused browser surface"))
            }
            found = tab
        }
        guard found.kind == "browser" else {
            throw ControlError(code: "invalid_params", message: ControlStrings.format("control.error.pageTabNotAppBrowser", "Tab %@ is not a browser tab of this app", found.id))
        }
        return Tab(id: found.id, url: found.url, browserProfileID: found.browserProfileID)
    }

    static func run(_ engine: any BrowserPageEngine, _ operation: BrowserPageOperation, _ tab: Tab) async throws -> JSONValue {
        do {
            return try await engine.run(operation, tabID: tab.id, url: tab.url)
        } catch let error as ControlError {
            throw error
        } catch {
            throw ControlError(code: "app_error", message: String(describing: error))
        }
    }

    static func base(_ tab: Tab) -> [String: JSONValue] { ["tab": .string(tab.id)] }

    static func string(_ call: ControlCall, _ key: String) throws -> String {
        guard let value = call.request.params[key]?.stringValue, !value.isEmpty else {
            throw ControlError.invalidParams(ControlStrings.format("control.error.missingParam", "%1$@ requires params.%2$@", call.request.method, key))
        }
        return value
    }
}
