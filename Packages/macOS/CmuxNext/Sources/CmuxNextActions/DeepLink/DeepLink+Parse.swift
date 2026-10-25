public import Foundation

nonisolated extension DeepLink {
    /// The link `url` names, when it is one in `scheme`.
    ///
    /// Nil for another scheme (another build's links are not opened here),
    /// the `auth-callback` host, an unknown host, a malformed id, extra path
    /// segments, a user, password or port, and a fragment other than a
    /// session's `#turn-<turnId>`. Query parameters other than `machine`, the
    /// legacy `stable_*_id` fallbacks and an agent link's `host`, `name` and
    /// `message` are ignored; an agent link's parameter cmux cannot use is
    /// dropped, and ``read(_:scheme:)`` names it.
    ///
    /// - Parameters:
    ///   - url: The URL to read.
    ///   - scheme: The running build's scheme; compared case-insensitively.
    /// - Returns: The link, or nil when `url` is not one.
    public static func parse(_ url: URL, scheme: String) -> DeepLink? {
        read(url, scheme: scheme)?.link
    }

    /// A link and the parameters it carried that cmux did not use.
    public nonisolated struct Parsed: Sendable, Hashable {
        /// The link itself.
        public var link: DeepLink
        /// Names, never values, of the parameters cmux ignored: ones no link of
        /// that kind reads, and (an agent link) one that is repeated or whose
        /// value is outside its charset. An ignored name never costs the link
        /// its target, so one stray parameter cannot drop a session; a caller
        /// that can say so shows them.
        public var ignoredParameters: [String]

        public init(link: DeepLink, ignoredParameters: [String] = []) {
            self.link = link
            self.ignoredParameters = ignoredParameters
        }
    }

    /// ``parse(_:scheme:)``, with the names of the parameters it ignored
    /// (schemas/deeplinks/agent-link.json).
    ///
    /// - Parameters:
    ///   - url: The URL to read.
    ///   - scheme: The running build's scheme; compared case-insensitively.
    /// - Returns: The link and what it ignored, or nil when `url` is not a link.
    public static func read(_ url: URL, scheme: String) -> Parsed? {
        guard let urlScheme = url.scheme, urlScheme.caseInsensitiveCompare(scheme) == .orderedSame,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.user == nil, components.password == nil, components.port == nil,
              let host = components.host?.lowercased(), !host.isEmpty else { return nil }
        let segments = components.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        let query = components.queryItems ?? []
        let fragment = components.fragment
        guard let target = target(host: host, segments: segments, query: query, fragment: fragment) else { return nil }
        var ignored: [String] = []
        var machine: String?
        let machineItems = query.filter { $0.name == machineKey }
        if !machineItems.isEmpty {
            // `?machine` with no value names no machine, which is how it always read; an agent
            // link still says it carried the name, as the page does (it cannot tell `?machine`
            // from `?machine=`).
            let machines = machineItems.compactMap(\.value)
            if target.isAgent {
                // One parameter cmux cannot read, or two that disagree, never costs an agent
                // link its session: the name is dropped and said.
                if machines.count == 1, machineItems.count == 1, isResourceID(machines[0], prefix: "machine_") {
                    machine = machines[0]
                } else {
                    ignored.append(machineKey)
                }
            } else if let first = machines.first {
                guard isResourceID(first, prefix: "machine_") else { return nil }
                machine = first
            }
        }
        var link = DeepLink(target, machine: machine)
        if target.isAgent {
            // Hints: one cmux cannot use is dropped and named, never a reason to refuse. A
            // repeated parameter has no single value, so neither side of a link guesses at it.
            func hint(_ name: String, _ fits: (String) -> Bool) -> String? {
                let items = query.filter { $0.name == name }
                guard !items.isEmpty else { return nil }
                guard items.count == 1, let value = items[0].value, fits(value) else {
                    ignored.append(name)
                    return nil
                }
                return value
            }
            link.hostHint = hint(hostHintKey, isHint)
            link.nameHint = hint(nameHintKey, isHint)
            link.message = hint(messageKey, isAgentMessage)
        }
        let known = parameters(of: target)
        ignored += query.map(\.name).filter { !known.contains($0) }
        var seen = Set<String>()
        return Parsed(link: link, ignoredParameters: ignored.filter { seen.insert($0).inserted })
    }

    /// The query parameter that names a target's machine.
    static let machineKey = "machine"

    /// The query parameters a link of this kind reads; every other name is
    /// ignored, so a link never carries a command.
    static func parameters(of target: Target) -> Set<String> {
        switch target {
        case .agent: [machineKey, hostHintKey, nameHintKey, messageKey]
        case .legacyWorkspace, .legacySurface: [machineKey, "stable_workspace_id", "stable_surface_id"]
        case .workspace, .pane, .tab, .session, .chiefSession, .group, .legacyPane: [machineKey]
        }
    }

    private static func target(host: String, segments: [String], query: [URLQueryItem], fragment: String?) -> Target? {
        guard let first = segments.first else { return nil }
        switch host {
        case "workspace":
            if let workspace = UUID(uuidString: first) {
                guard fragment == nil else { return nil }
                return legacy(workspace, segments: segments, query: query)
            }
            guard segments.count == 1, fragment == nil, isResourceID(first, prefix: "ws_") else { return nil }
            return .workspace(first)
        case "pane":
            guard segments.count == 1, fragment == nil, isResourceID(first, prefix: "pane_") else { return nil }
            return .pane(first)
        case "tab":
            guard segments.count == 1, fragment == nil, isResourceID(first, prefix: "tab_") else { return nil }
            return .tab(first)
        case "chief":
            guard segments.count == 3, segments[1] == "session", fragment == nil,
                  isChiefHome(first), isToken(segments[2]) else { return nil }
            return .chiefSession(home: first, session: segments[2])
        case "group":
            guard fragment == nil, isGroupID(first) else { return nil }
            if segments.count == 1 { return .group(first, workspace: nil) }
            guard segments.count == 3, segments[1] == "workspace", isResourceID(segments[2], prefix: "ws_") else { return nil }
            return .group(first, workspace: segments[2])
        case "agent":
            guard segments.count == 2, fragment == nil, isHarness(first), isAgentSession(segments[1]) else { return nil }
            return .agent(harness: first, session: segments[1])
        case "session":
            guard segments.count == 1, isToken(first) else { return nil }
            guard let fragment else { return .session(first, turn: nil) }
            guard fragment.hasPrefix(turnFragmentPrefix) else { return nil }
            let turn = String(fragment.dropFirst(turnFragmentPrefix.count))
            guard isToken(turn) else { return nil }
            return .session(first, turn: turn)
        default:
            // Includes `auth-callback`, the sign-in callback.
            return nil
        }
    }

    /// The hosts that serve a cloud group's https hand-off page (`GET /g/<id>[/w/<ws_>]`): the
    /// cmux Cloud API Worker (production and staging) and cmux.com.
    public static let groupWebHosts: Set<String> = ["cloud-api.cmux.dev", "cloud-api-staging.cmux.dev", "cmux.com", "www.cmux.com"]

    /// The cloud group link an https URL names (`https://cloud-api.cmux.dev/g/grp_…`, optionally
    /// `/w/ws_…`), so a click on the web form in the app opens it here, not in a browser.
    ///
    /// - Parameter url: The URL to read.
    /// - Returns: The group link, or nil for any other URL (another host, a port, a user, a
    ///   query, a fragment, or a malformed id).
    public static func parseGroupWeb(_ url: URL) -> DeepLink? {
        guard url.scheme?.lowercased() == "https",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.user == nil, components.password == nil, components.port == nil,
              components.query == nil, components.fragment == nil,
              let host = components.host?.lowercased(), groupWebHosts.contains(host) else { return nil }
        let segments = components.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard segments.count >= 2, segments[0] == "g", isGroupID(segments[1]) else { return nil }
        if segments.count == 2 { return DeepLink(.group(segments[1], workspace: nil)) }
        guard segments.count == 4, segments[2] == "w", isResourceID(segments[3], prefix: "ws_") else { return nil }
        return DeepLink(.group(segments[1], workspace: segments[3]))
    }

    /// Nightly's grammar (`CmuxNavigationURLRequest`): `workspace/<uuid>`,
    /// optionally followed by `pane/<uuid>`, `surface/<uuid>` or
    /// `panel/<uuid>`.
    private static func legacy(_ workspace: UUID, segments: [String], query: [URLQueryItem]) -> Target? {
        guard let fallbackWorkspace = stableID("stable_workspace_id", in: query),
              let fallbackSurface = stableID("stable_surface_id", in: query) else { return nil }
        if segments.count == 1 { return .legacyWorkspace(workspace, fallback: fallbackWorkspace) }
        guard segments.count == 3, let child = UUID(uuidString: segments[2]) else { return nil }
        switch segments[1].lowercased() {
        case "pane":
            return .legacyPane(workspace: workspace, pane: child)
        case "surface", "panel":
            return .legacySurface(workspace: workspace, surface: child,
                                  fallbackWorkspace: fallbackWorkspace, fallbackSurface: fallbackSurface)
        default:
            return nil
        }
    }

    /// The UUID of the query item `name`: `.some(nil)` when absent, nil when
    /// present but not a UUID (a malformed link, as nightly refused it).
    private static func stableID(_ name: String, in query: [URLQueryItem]) -> UUID?? {
        guard let item = query.first(where: { $0.name == name }) else { return .some(nil) }
        guard let value = item.value, let id = UUID(uuidString: value) else { return nil }
        return .some(id)
    }
}
