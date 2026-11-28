public import Foundation

nonisolated extension DeepLink {
    /// The link `url` names, when it is one in `scheme`.
    ///
    /// Nil for another scheme (another build's links are not opened here),
    /// the `auth-callback` host, an unknown host, a malformed id, extra path
    /// segments, a user, password or port, and a fragment other than a
    /// session's `#turn-<turnId>`. Query parameters other than `machine` and
    /// the legacy `stable_*_id` fallbacks are ignored.
    ///
    /// - Parameters:
    ///   - url: The URL to read.
    ///   - scheme: The running build's scheme; compared case-insensitively.
    /// - Returns: The link, or nil when `url` is not one.
    public static func parse(_ url: URL, scheme: String) -> DeepLink? {
        guard let urlScheme = url.scheme, urlScheme.caseInsensitiveCompare(scheme) == .orderedSame,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.user == nil, components.password == nil, components.port == nil,
              let host = components.host?.lowercased(), !host.isEmpty else { return nil }
        let segments = components.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        let query = components.queryItems ?? []
        var machine: String?
        if let value = query.first(where: { $0.name == "machine" })?.value {
            guard isResourceID(value, prefix: "machine_") else { return nil }
            machine = value
        }
        let fragment = components.fragment
        guard let target = target(host: host, segments: segments, query: query, fragment: fragment) else { return nil }
        return DeepLink(target, machine: machine)
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
