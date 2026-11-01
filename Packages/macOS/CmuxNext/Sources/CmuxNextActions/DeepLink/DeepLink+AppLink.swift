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
