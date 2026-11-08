public import Foundation

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
        case .workspace, .pane, .tab, .session, .agent, .group:
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

    /// The action a settings link runs: `cmux://settings/background` (Chief's first-launch welcome
    /// offers it) is Change Background…, the same action as the command palette, the context menus and
    /// `cmux settings change-background`.
    /// - Parameters:
    ///   - url: The clicked link.
    ///   - linkScheme: This build's own scheme; the `cmux` scheme is taken too.
    /// - Returns: The action's id, or nil for any other URL.
    public static func settingsAction(for url: URL, linkScheme: String) -> ActionID? {
        guard let scheme = url.scheme?.lowercased(), scheme == chiefScheme || scheme == linkScheme.lowercased(),
              url.host?.lowercased() == "settings" else { return nil }
        return url.path.lowercased() == "/background" ? "appearance.changeBackground" : nil
    }
}
