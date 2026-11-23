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
        var request = DeepLinkRust.Request("appLink", url: url, scheme: linkScheme)
        request.chief = chiefHost != nil
        return DeepLinkRust.optional(request, as: DeepLink.self)
    }

    /// The agent link an https agent session link names (`https://cmux.com/deeplink/agent?harness=
    /// claude&session=…&host=…`, with or without a locale segment or a trailing slash), read as its
    /// `cmux://agent/<harness>/<session>` form, so a click on it in the app opens the chat here, not
    /// its web page (Leo, 2026-11-03: "we need to be able to link WITHIN THE APP"). Nil for any
    /// other URL, and for the opaque `?id=` form, which names no session.
    public static func parseAgentWeb(_ url: URL) -> DeepLink? {
        DeepLinkRust.optional(.init("agentWeb", url: url), as: DeepLink.self)
    }

    /// The harness session id an https agent link names when it names no harness (`?host=&session=`,
    /// as lanes print them): acpmux resolves a bare id against its chats' agent session ids. Nil for
    /// any other URL, and for a link with a harness (``parseAgentWeb(_:)`` reads that one).
    public static func agentWebSession(_ url: URL) -> String? {
        DeepLinkRust.optional(.init("agentWebSession", url: url), as: String.self)
    }

    /// The opaque agent reference (`aid-` and 20 lowercase hex digits) a link names in place of a
    /// session: `cmux://agent?id=aid-…` (what cmux.com's page hands the app, in the `cmux` scheme or
    /// `linkScheme`) or the page's own form `https://cmux.com/deeplink/agent?id=aid-…`, which every
    /// public PR footer carries. The app never looks it up itself: acpmux resolves it
    /// (`_acpmux/resolve`, `opaque_agent_id.rs`) by hashing the chats this Mac and its peers list
    /// under this Mac's key, so it opens only a chat the reader can already reach. Nil for any other
    /// URL, for one that also names a harness or session, and for an `id` written twice.
    public static func agentReference(_ url: URL, linkScheme: String) -> String? {
        DeepLinkRust.optional(.init("agentReference", url: url, scheme: linkScheme), as: String.self)
    }

    /// Whether `url` opens an agent's chat: an agent link (`cmux://agent/<harness>/<session>`) or an
    /// opaque reference (``agentReference(_:linkScheme:)``). Such a link opened from another app is an
    /// address from a public page or trailer, so it never takes the keys (`ExternalOpenController`).
    public static func opensAgentChat(_ url: URL, linkScheme: String) -> Bool {
        DeepLinkRust.call(.init("opensAgentChat", url: url, scheme: linkScheme), as: Bool.self) ?? false
    }

    /// `aid-` and 20 lowercase hex digits: the opaque id agent-identity writes (cmux.com's
    /// `AGENT_REFERENCE_PATTERN`, acpmux's `opaque_agent_id::is_id`).
    public static func isAgentReference(_ text: String) -> Bool { DeepLinkRust.valid("agentReference", text) }

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
    /// - Returns: The action and its arguments, or nil for any other URL.
    public static func settingsAction(for url: URL, linkScheme: String) -> SettingsLinkAction? {
        DeepLinkRust.optional(.init("settingsPath", url: url, scheme: linkScheme), as: String.self)
            .flatMap { settingsRoutes[$0] }
    }

    /// The Settings page place a settings link opens: `cmux://settings/models` is Settings > Models
    /// (`#/settings/models`), `cmux://settings/models/add` its Add a Connection
    /// (`#/settings/models?focus=models.add`). `cmux://settings/cloud` is Settings > Cloud, and
    /// `cmux://settings/cloud/claude`, `/cloud/chatgpt` and `/cloud/api-key` open it on that row of
    /// Models for Cloud (``cloudRoute(row:)``). Nil for any other URL.
    public static func settingsRoute(for url: URL, linkScheme: String) -> String? {
        DeepLinkRust.optional(.init("settingsRoute", url: url, scheme: linkScheme), as: String.self)
    }

    /// Settings > Cloud (`#/settings/cloud`), opened on a row of its Models for Cloud card
    /// (`claude`, `chatgpt`, `apiKey`: `?focus=cloud.<row>`) when one is named.
    public static func cloudRoute(row: String?) -> String {
        var request = DeepLinkRust.Request("cloudRoute")
        request.row = row
        return DeepLinkRust.call(request, as: String.self) ?? "#/settings/cloud"
    }

    /// The settings link path that turns Start Agent from Any App on.
    public static let startAgentFromAnyAppPath = "/start-agent-from-any-app"

    /// Every settings link path the app runs, and what it runs: the one list. Home draws a link only
    /// for a path it renders (MessagesLabHome's `URL.homeSettingsLinkPaths`), so a path added here and
    /// not there would show as plain text; `HomeCmuxAppLinkTests` holds the two lists equal.
    public static let settingsRoutes: [String: SettingsLinkAction] = [
        "/background": SettingsLinkAction("appearance.changeBackground"),
        startAgentFromAnyAppPath: SettingsLinkAction(
            "palette.toggleSetting", arguments: ["setting": .string("app.startAgentGlobalHotKey"), "on": .bool(true)]),
    ]
}
