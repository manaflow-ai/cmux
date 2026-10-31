public import Foundation

extension DeepLink {
    /// The scheme the Chief and its documents write, whatever the build.
    public static let chiefScheme = "cmux"

    /// The link `url` opens in this app, in the `cmux` scheme or `linkScheme` (this build's): a
    /// workspace, pane, tab, chat session or outside agent session; a Chief subagent's chat only for this app's own
    /// Chief home (`chiefHost`, `chief:<home id>`) and on this machine. Nil for anything else (an
    /// unknown scheme or host, a malformed id, a legacy UUID link, another Chief's subagent).
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
        case .chiefSession(let home, _):
            return link.machine == nil && chiefHost == "chief:" + home ? link : nil
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
