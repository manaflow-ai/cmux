public import Foundation
import os

extension DeepLink {
    /// The scheme the Chief and its documents write, whatever the build.
    public static let chiefScheme = "cmux"

    /// The link `url` opens in this app, in the `cmux` scheme or `linkScheme` (this build's): a
    /// workspace, pane, tab, chat session or outside agent session; a Chief subagent's chat on this
    /// machine when this app has a Chief (`chiefHost`), for any Chief home: a named Chief's links
    /// name its own home id, not the app's (#28877), and opening checks the home
    /// (`ChiefSidebar.openSubagentLink`). Nil for anything else (an unknown scheme or host, a
    /// malformed id, a legacy UUID link, another machine's subagent).
    /// - Parameters:
    ///   - url: The clicked link.
    ///   - linkScheme: This build's own scheme (`cmux-dev-<tag>` for a tagged build).
    ///   - chiefHost: This app's Chief host (`chief:<home id>`), nil when it has none.
    /// - Returns: The link to open, or nil.
    public static func appLink(for url: URL, linkScheme: String, chiefHost: String?) -> DeepLink? {
        // A cloud group's https form (`https://cloud-api.cmux.dev/g/grp_…`) opens here too.
        guard let link = parse(url, scheme: chiefScheme) ?? parse(url, scheme: linkScheme) ?? parseGroupWeb(url) else { return nil }
        switch link.target {
        case .workspace, .pane, .tab, .session, .agent, .group, .cloudSession:
            return link
        case .chiefSession: // any Chief home of this Mac: a named Chief writes its own (#28877)
            return link.machine == nil && chiefHost != nil ? link : nil
        case .legacyWorkspace, .legacyPane, .legacySurface:
            return nil
        }
    }

    /// The hosts that serve the agent session link's web page (`/deeplink/agent?harness=&session=`,
    /// the link every PR footer and agent reply carries).
    public static let agentWebHosts: Set<String> = ["cmux.com", "www.cmux.com"]

    /// The agent link an https agent session link names (`https://cmux.com/deeplink/agent?harness=
    /// claude&session=…&host=…`, with or without a locale segment or a trailing slash), read as its
    /// `cmux://agent/<harness>/<session>` form, so a click on it in the app opens the chat here, not
    /// its web page (Leo, 2026-11-03: "we need to be able to link WITHIN THE APP"). Nil for any
    /// other URL, and for the opaque `?id=` form, which names no session.
    public static func parseAgentWeb(_ url: URL) -> DeepLink? {
        guard let query = agentWebQuery(url) else { return nil }
        func one(_ name: String) -> String? {
            let items = query.filter { $0.name == name }
            return items.count == 1 ? items[0].value : nil
        }
        guard let harness = one("harness"), let session = one("session") else { return nil }
        var native = URLComponents()
        native.scheme = chiefScheme
        native.host = "agent"
        native.percentEncodedPath = "/" + [harness, session].map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? $0 }.joined(separator: "/")
        let hints = query.filter { [hostHintKey, nameHintKey, messageKey].contains($0.name) }
        native.queryItems = hints.isEmpty ? nil : hints
        guard let link = native.url.flatMap({ parse($0, scheme: chiefScheme) }), link.target.isAgent else { return nil }
        return link
    }

    /// The harness session id an https agent link names when it names no harness (`?host=&session=`,
    /// as lanes print them): acpmux resolves a bare id against its chats' agent session ids. Nil for
    /// any other URL, and for a link with a harness (``parseAgentWeb(_:)`` reads that one).
    public static func agentWebSession(_ url: URL) -> String? {
        guard let query = agentWebQuery(url), !query.contains(where: { $0.name == "harness" }) else { return nil }
        let sessions = query.filter { $0.name == "session" }
        guard sessions.count == 1, let session = sessions[0].value, isAgentSession(session) else { return nil }
        return session
    }

    /// The opaque agent reference (`aid-` and 20 lowercase hex digits) a link names in place of a
    /// session: `cmux://agent?id=aid-…` (what cmux.com's page hands the app, in the `cmux` scheme or
    /// `linkScheme`) or the page's own form `https://cmux.com/deeplink/agent?id=aid-…`, which every
    /// public PR footer carries. The app never looks it up itself: acpmux resolves it
    /// (`_acpmux/resolve`, `opaque_agent_id.rs`) by hashing the chats this Mac and its peers list
    /// under this Mac's key, so it opens only a chat the reader can already reach. Nil for any other
    /// URL, for one that also names a harness or session, and for an `id` written twice.
    public static func agentReference(_ url: URL, linkScheme: String) -> String? {
        let query: [URLQueryItem]
        if let web = agentWebQuery(url) {
            query = web
        } else {
            guard let scheme = url.scheme?.lowercased(), scheme == chiefScheme || scheme == linkScheme.lowercased(),
                  let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  components.host?.lowercased() == "agent", components.path.isEmpty || components.path == "/",
                  components.user == nil, components.port == nil, components.fragment == nil else { return nil }
            query = components.queryItems ?? []
        }
        guard !query.contains(where: { $0.name == "harness" || $0.name == "session" }) else { return nil }
        let ids = query.filter { $0.name == "id" }
        guard ids.count == 1, let id = ids[0].value, isAgentReference(id) else { return nil }
        return id
    }

    /// Whether `url` opens an agent's chat: an agent link (`cmux://agent/<harness>/<session>`) or an
    /// opaque reference (``agentReference(_:linkScheme:)``). Such a link opened from another app is an
    /// address from a public page or trailer, so it never takes the keys (`ExternalOpenController`).
    public static func opensAgentChat(_ url: URL, linkScheme: String) -> Bool {
        if agentReference(url, linkScheme: linkScheme) != nil { return true }
        if case .agent = read(url, scheme: linkScheme)?.link.target { return true }
        return false
    }

    /// `aid-` and 20 lowercase hex digits: the opaque id agent-identity writes (cmux.com's
    /// `AGENT_REFERENCE_PATTERN`, acpmux's `opaque_agent_id::is_id`).
    public static func isAgentReference(_ text: String) -> Bool {
        // The count too: `$` also matches before a final newline a decoded `%0A` could leave.
        text.utf8.count == 24 && text.range(of: "^aid-[0-9a-f]{20}$", options: .regularExpression) != nil
    }

    /// The query of an https agent session link's page (cmux.com, `/deeplink/agent`, an optional
    /// locale segment and trailing slash; no user, port or fragment), nil for any other URL.
    private static func agentWebQuery(_ url: URL) -> [URLQueryItem]? {
        guard url.scheme?.lowercased() == "https",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.user == nil, components.password == nil, components.port == nil, components.fragment == nil,
              let host = components.host?.lowercased(), agentWebHosts.contains(host) else { return nil }
        let segments = components.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        let path = segments.count == 3 && isLocale(segments[0]) ? Array(segments.dropFirst()) : segments
        return path == ["deeplink", "agent"] ? components.queryItems ?? [] : nil
    }

    /// A cmux.com locale segment (`en`, `zh-CN`).
    private static func isLocale(_ segment: String) -> Bool {
        segment.range(of: "^[a-z]{2}(-[A-Z]{2})?$", options: .regularExpression) != nil
    }

    /// What a settings link runs: an action and its arguments, run as the person's click.
    public nonisolated struct SettingsLinkAction: Sendable, Equatable {
        /// The action's id.
        public let id: ActionID
        /// Its arguments.
        public let arguments: [String: ActionValue]

        public init(_ id: ActionID, arguments: [String: ActionValue] = [:]) {
            self.id = id
            self.arguments = arguments
        }

        /// Logs that the clicked link `url` ran this action (its id, its argument keys, done or refused;
        /// category app.links, which the onboarding walk's turn-on row reads) and returns `done`.
        public func ran(from url: URL, done: Bool) -> Bool {
            let keys = arguments.keys.sorted().joined(separator: ",")
            Logger(subsystem: "com.cmuxterm.app.next", category: "app.links")
                .notice("app link \(url.host ?? "", privacy: .public)\(url.path, privacy: .public) ran \(id.rawValue, privacy: .public) \(keys, privacy: .public): \(done ? "done" : "refused", privacy: .public)")
            return done
        }
    }

    /// The action a settings link runs: `cmux://settings/background` (Chief's first-launch welcome
    /// offers it) is Change Background…, the same action as the command palette, the context menus and
    /// `cmux settings change-background`; `cmux://settings/start-agent-from-any-app` (the welcome's
    /// shortcut list offers it while it is off) turns `app.startAgentGlobalHotKey` on through Toggle
    /// Setting, as `cmux settings set app.startAgentGlobalHotKey true` does. A link only turns it on,
    /// never off.
    /// - Parameters:
    ///   - url: The clicked link.
    ///   - linkScheme: This build's own scheme; the `cmux` scheme is taken too.
    /// An app install link (`cmux://apps/install?repo=…`, ``appInstallAction(for:linkScheme:)``)
    /// runs `app.install` the same way, so a click shows the App Store's consent card.
    /// - Returns: The action and its arguments, or nil for any other URL.
    public static func settingsAction(for url: URL, linkScheme: String) -> SettingsLinkAction? {
        if let install = appInstallAction(for: url, linkScheme: linkScheme) { return install }
        guard let scheme = url.scheme?.lowercased(), scheme == chiefScheme || scheme == linkScheme.lowercased(),
              url.host?.lowercased() == "settings" else { return nil }
        return settingsRoutes[url.path.lowercased()]
    }

    /// The Settings page place a settings link opens: `cmux://settings/models` is Settings > Models
    /// (`#/settings/models`), `cmux://settings/models/add` its Add a Connection
    /// (`#/settings/models?focus=models.add`). `cmux://settings/cloud` is Settings > Cloud, and
    /// `cmux://settings/cloud/claude`, `/cloud/chatgpt` and `/cloud/api-key` open it on that row of
    /// Models for Cloud (``cloudRoute(row:)``). `cmux://settings/integrations` (or `/connections`) is
    /// Settings > Integrations, where a connector's sign-in returns (`?connected=` or `?error=` are left
    /// to the page's own refresh). `cmux://settings/connections/github` (or `/github`,
    /// `/accounts/github`) is the GitHub connection on Settings > Accounts. Every other settings path
    /// passes through to the page (``settingsPassThrough(_:)``); nil for an action path
    /// (``settingsRoutes``) or another URL.
    public static func settingsRoute(for url: URL, linkScheme: String) -> String? {
        guard let scheme = url.scheme?.lowercased(), scheme == chiefScheme || scheme == linkScheme.lowercased(),
              url.host?.lowercased() == "settings" else { return nil }
        switch url.path.lowercased() {
        case "/models", "/models/": return "#/settings/models"
        case "/models/add", "/models/add/": return "#/settings/models?focus=models.add"
        case "/cloud", "/cloud/": return cloudRoute(row: nil)
        case "/cloud/claude", "/cloud/claude/": return cloudRoute(row: "claude")
        case "/cloud/chatgpt", "/cloud/chatgpt/": return cloudRoute(row: "chatgpt")
        case "/cloud/api-key", "/cloud/api-key/": return cloudRoute(row: "apiKey")
        case "/integrations", "/integrations/", "/connections", "/connections/": return "#/settings/integrations"
        case "/github", "/github/", "/connections/github", "/connections/github/", "/accounts/github", "/accounts/github/":
            return "#/settings/accounts?focus=connection.github"
        default: return settingsPassThrough(url.path)
        }
    }

    /// Any other settings link reaches the page as written, and the page's one registry resolves it
    /// (webviews settingsLinks.ts): `cmux://settings/<a>` is `#/settings/<a>`, `cmux://settings/<a>/<b>`
    /// `#/settings/<a>?focus=<b>` (more segments join with dots). So every category, alias, card,
    /// setting key and connection has a link (`cmux://settings/terminal.fontSize`,
    /// `cmux://settings/accounts/machines`, `cmux://settings/connections/linear`), and a name the page
    /// does not know is named there instead of nothing opening. `cmux://settings` alone opens the page.
    /// The action paths (``settingsRoutes``) stay actions.
    static func settingsPassThrough(_ path: String) -> String? {
        if settingsRoutes[path.lowercased()] != nil { return nil }
        let segments = path.split(separator: "/").map(String.init)
        guard let section = segments.first else { return "#/settings" }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        guard let first = section.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        guard segments.count > 1 else { return "#/settings/\(first)" }
        guard let focus = segments.dropFirst().joined(separator: ".").addingPercentEncoding(withAllowedCharacters: allowed)
        else { return nil }
        return "#/settings/\(first)?focus=\(focus)"
    }

    /// Settings > Cloud (`#/settings/cloud`), opened on a row of its Models for Cloud card
    /// (`claude`, `chatgpt`, `apiKey`: `?focus=cloud.<row>`) when one is named.
    public static func cloudRoute(row: String?) -> String {
        row.map { "#/settings/cloud?focus=cloud.\($0)" } ?? "#/settings/cloud"
    }
    /// The settings link path that turns Start Agent from Any App on.
    public nonisolated static let startAgentFromAnyAppPath = "/start-agent-from-any-app"

    /// Every settings link path the app runs, and what it runs: the one list. Home draws a link only
    /// for a path it renders (MessagesLabHome's `URL.homeSettingsLinkPaths`), so a path added here and
    /// not there would show as plain text; `HomeCmuxAppLinkTests` holds the two lists equal.
    public static let settingsRoutes: [String: SettingsLinkAction] = [
        "/background": SettingsLinkAction("appearance.changeBackground"),
        startAgentFromAnyAppPath: SettingsLinkAction(
            "palette.toggleSetting", arguments: ["setting": .string("app.startAgentGlobalHotKey"), "on": .bool(true)]),
    ]
}
