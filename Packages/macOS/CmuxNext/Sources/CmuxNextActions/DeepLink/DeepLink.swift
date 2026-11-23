public import Foundation

/// A link to one object in cmux, such as `cmux://tab/tab_<hex>`.
///
/// The scheme is the running build's URL scheme, the one the sign-in
/// callback uses (`CloudConfiguration.callbackScheme`: `cmux` in Release,
/// `cmux-dev` in Debug, `cmux-dev-<tag>` in tagged builds). The host names
/// the kind and the one path segment is an opaque cmux-tui resource id
/// (`ws_`, `pane_`, `tab_` plus 32 lowercase hex digits), never a numeric
/// handle. `?machine=machine_<hex>` may name the machine the target lives on;
/// every other query parameter is ignored, so a link can never carry a
/// command. The `auth-callback` host is the sign-in callback, never a link.
///
/// Nightly's `cmux://workspace/<uuid>[/pane/<uuid>|/surface/<uuid>|/panel/<uuid>]`
/// forms, with their `stable_workspace_id` and `stable_surface_id`
/// fallbacks, parse to the `legacy` targets.
///
/// ```swift
/// let link = DeepLink(.tab("tab_0123456789abcdef0123456789abcdef"))
/// let url = link.url(scheme: "cmux")        // cmux://tab/tab_0123…
/// DeepLink.parse(url!, scheme: "cmux") == link  // true
/// ```
public nonisolated struct DeepLink: Sendable, Hashable, Codable {
    /// What a link opens.
    public nonisolated enum Target: Sendable, Hashable, Codable {
        /// A workspace by its `ws_` resource id.
        case workspace(String)
        /// A pane by its `pane_` resource id; it opens on the pane's selected tab.
        case pane(String)
        /// A terminal, browser or agent tab by its `tab_` resource id.
        case tab(String)
        /// An acpmux agent chat session, and optionally one turn in it
        /// (`#turn-<turnId>`).
        case session(String, turn: String?)
        /// A Chief subagent's chat: acpmux session `session` in the Chief home whose id is
        /// `home` (8 lowercase hex, optchat-chief `paths::home_id`), whose agent tabs record
        /// host `chief:<home>`. The Chief writes it in its text (`workspaces::subagent_link`).
        case chiefSession(home: String, session: String)
        /// An outside agent's session by the harness's own id (hq#2555):
        /// `agent/<harness>/<harnessSessionId>`, where the harness is an acpmux
        /// name (`claude`, `codex`, `opencode`, …) and the session is the id the
        /// harness gives it (`CLAUDE_CODE_SESSION_ID`, `CODEX_THREAD_ID`). An
        /// address, not a credential: it opens only a tab this app already
        /// shows that session in. Its `?host=`, `?name=` and `?message=`
        /// parameters, and what happens to one cmux cannot use, are
        /// schemas/deeplinks/agent-link.json, the schema cmux.com's deeplink
        /// page writes these links by.
        case agent(harness: String, session: String)
        /// A cloud group (plans/cmux-next/cloud-groups-DESIGN.md) by the `grp_` id cmux Cloud
        /// minted for it, and optionally one of its workspaces (`group/<id>/workspace/<ws_>`).
        /// The group's record lives in the team's cloud directory, so the link means the same
        /// thing on every Mac, the iPhone and every Chief.
        case group(String, workspace: String?)
        /// A team's Cloud chat or workspace (contract C5): `cloud/session/<team>/<vm>/<session>` or
        /// `cloud/workspace/<team>/<vm>/<workspace>`. Its record lives in the team's TeamDO, so it opens
        /// for every member of the team; a person outside it is refused (``cloudSessionPlan``).
        case cloudSession(team: String, machine: String, session: String, kind: CloudSessionKind)
        /// Nightly's `workspace/<uuid>`: the durable workspace key, with the
        /// `stable_workspace_id` fallback.
        case legacyWorkspace(UUID, fallback: UUID?)
        /// Nightly's `workspace/<uuid>/pane/<uuid>`.
        case legacyPane(workspace: UUID, pane: UUID)
        /// Nightly's `workspace/<uuid>/surface/<uuid>` (or `/panel/`), with the
        /// `stable_workspace_id` and `stable_surface_id` fallbacks.
        case legacySurface(workspace: UUID, surface: UUID, fallbackWorkspace: UUID?, fallbackSurface: UUID?)
    }

    /// The object the link opens.
    public var target: Target
    /// The `machine_` resource id of the machine the target lives on, when
    /// the link names one. Ids are globally unique, so it is a hint for the
    /// refusal, never needed to find the target.
    public var machine: String?
    /// An agent link's `?host=` display hint: the name of the machine the
    /// agent ran on. Never used to find the session or to trust the link.
    public var hostHint: String?
    /// An agent link's `?name=` display hint: the agent's name. Never used to
    /// find the session or to trust the link.
    public var nameHint: String?
    /// An agent link's `?message=`: one message of that session to scroll to
    /// and highlight once it opens, by the harness message id acpmux reports
    /// for it. A message this machine's transcript does not have leaves the
    /// view where it is; it never finds or trusts the session.
    public var message: String?

    /// A link to `target`.
    ///
    /// - Parameters:
    ///   - target: The object the link opens.
    ///   - machine: The `machine_` id of a remote machine; nil for none.
    ///   - hostHint: An agent link's machine name for display; nil for none.
    ///   - nameHint: An agent link's agent name for display; nil for none.
    ///   - message: An agent link's message to scroll to; nil for none.
    public init(_ target: Target, machine: String? = nil, hostHint: String? = nil, nameHint: String? = nil,
                message: String? = nil) {
        self.target = target
        self.machine = machine
        self.hostHint = hostHint
        self.nameHint = nameHint
        self.message = message
    }

    /// The host of the sign-in callback (`<scheme>://auth-callback`), which
    /// is never a link.
    public static let authCallbackHost = "auth-callback"

    /// The link as a URL in `scheme`, the running build's scheme.
    ///
    /// - Parameter scheme: The URL scheme (`cmux`, `cmux-dev`, `cmux-dev-<tag>`).
    /// - Returns: The URL, or nil when an id does not fit its kind's grammar,
    ///   so a formatted link always parses back to the same value.
    public func url(scheme: String) -> URL? {
        DeepLinkRust.optional(.init("url", scheme: scheme, link: self), as: String.self).flatMap(URL.init(string:))
    }

    /// The names of the parameters this link carries a value for.
    ///
    /// A reader that names what a link ignored never denies one of these: a stray name of its own
    /// (`?host%20=x` beside `?host=big-red`) can be shown as a parameter's name, and saying that
    /// name was ignored would contradict the chat the link opened
    /// (schemas/deeplinks/agent-link.json `ignoredOrder`). An agent link's harness and session
    /// count too: the page carries them as parameters (`pathParams`).
    public var usedParameters: Set<String> {
        Set(DeepLinkRust.call(.init("usedParameters", link: self), as: [String].self) ?? [])
    }

    /// `<prefix>` plus 128 bits as 32 lowercase hex digits
    /// (cmux-tui/spec/resource-api-v2.md).
    static func isResourceID(_ text: String, prefix: String) -> Bool {
        DeepLinkRust.valid("resourceID", text, prefix: prefix)
    }

    /// An acpmux harness name (`claude`, `codex`, `opencode`): 1 to 64
    /// lowercase ASCII letters, digits or `-`.
    static func isHarness(_ text: String) -> Bool { DeepLinkRust.valid("harness", text) }

    /// A display hint (`?host=`, `?name=`): a token of at most 64 characters,
    /// not only dots.
    static func isHint(_ text: String) -> Bool { DeepLinkRust.valid("hint", text) }

    /// An agent link's harness session id: up to 256 bytes, `:` allowed, not only dots.
    static func isAgentSession(_ text: String) -> Bool { DeepLinkRust.valid("agentSession", text) }

    /// Agent message ids retain the original token grammar.
    static func isAgentMessage(_ text: String) -> Bool { DeepLinkRust.valid("agentMessage", text) }
}
