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
public nonisolated struct DeepLink: Sendable, Hashable {
    /// What a link opens.
    public nonisolated enum Target: Sendable, Hashable {
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
        /// Nightly's `workspace/<uuid>`: the durable workspace key, with the
        /// `stable_workspace_id` fallback.
        case legacyWorkspace(UUID, fallback: UUID?)
        /// Nightly's `workspace/<uuid>/pane/<uuid>`.
        case legacyPane(workspace: UUID, pane: UUID)
        /// Nightly's `workspace/<uuid>/surface/<uuid>` (or `/panel/`), with the
        /// `stable_workspace_id` and `stable_surface_id` fallbacks.
        case legacySurface(workspace: UUID, surface: UUID, fallbackWorkspace: UUID?, fallbackSurface: UUID?)

        var isAgent: Bool {
            if case .agent = self { return true }
            return false
        }
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
        guard isWellFormed, Self.isScheme(scheme) else { return nil }
        var text = "\(scheme)://"
        var query: [String] = []
        var fragment: String?
        switch target {
        case .workspace(let id): text += "workspace/\(id)"
        case .pane(let id): text += "pane/\(id)"
        case .tab(let id): text += "tab/\(id)"
        case .session(let id, let turn):
            text += "session/\(id)"
            fragment = turn.map { Self.turnFragmentPrefix + $0 }
        case .chiefSession(let home, let session): text += "chief/\(home)/session/\(session)"
        case .group(let id, let workspace):
            text += "group/\(id)"
            if let workspace { text += "/workspace/\(workspace)" }
        case .agent(let harness, let session):
            text += "agent/\(harness)/\(session)"
            // The order schemas/deeplinks/agent-link.json states, so every emitter writes the
            // same link for the same chat.
            if let hostHint { query.append("\(Self.hostHintKey)=\(hostHint)") }
            if let nameHint { query.append("\(Self.nameHintKey)=\(nameHint)") }
            if let message { query.append("\(Self.messageKey)=\(message)") }
        case .legacyWorkspace(let workspace, let fallback):
            text += "workspace/\(workspace.uuidString)"
            if let fallback { query.append("stable_workspace_id=\(fallback.uuidString)") }
        case .legacyPane(let workspace, let pane):
            text += "workspace/\(workspace.uuidString)/pane/\(pane.uuidString)"
        case .legacySurface(let workspace, let surface, let fallbackWorkspace, let fallbackSurface):
            text += "workspace/\(workspace.uuidString)/surface/\(surface.uuidString)"
            if let fallbackWorkspace { query.append("stable_workspace_id=\(fallbackWorkspace.uuidString)") }
            if let fallbackSurface { query.append("stable_surface_id=\(fallbackSurface.uuidString)") }
        }
        if let machine { query.append("machine=\(machine)") }
        if !query.isEmpty { text += "?" + query.joined(separator: "&") }
        if let fragment { text += "#" + fragment }
        return URL(string: text)
    }

    /// The names of the parameters this link carries a value for.
    ///
    /// A reader that names what a link ignored never denies one of these: a stray name of its own
    /// (`?host%20=x` beside `?host=big-red`) can be shown as a parameter's name, and saying that
    /// name was ignored would contradict the chat the link opened
    /// (schemas/deeplinks/agent-link.json `ignoredOrder`).
    public var usedParameters: Set<String> {
        var names: Set<String> = []
        // An agent link carries its harness and session in the path, where the page carries them
        // as parameters (schemas/deeplinks/agent-link.json `pathParams`), so a stray `?session=x`
        // beside `cmux://agent/claude/s1` must not read as a session the link left out either.
        if case .agent = target { names.formUnion(Self.agentPathKeys) }
        if machine != nil { names.insert(Self.machineKey) }
        if hostHint != nil { names.insert(Self.hostHintKey) }
        if nameHint != nil { names.insert(Self.nameHintKey) }
        if message != nil { names.insert(Self.messageKey) }
        return names
    }

    /// The fragment that names a turn: `#turn-<turnId>`.
    static let turnFragmentPrefix = "turn-"

    /// What the page calls the two parts of an agent link's path
    /// (schemas/deeplinks/agent-link.json `pathParams`).
    static let agentPathKeys: Set<String> = ["harness", "session"]

    /// The query parameters of an agent link's display hints.
    static let hostHintKey = "host"
    static let nameHintKey = "name"
    /// The query parameter that names one message of an agent link's session.
    static let messageKey = "message"

    /// Whether every id fits its kind's grammar (``parse(_:scheme:)``).
    var isWellFormed: Bool {
        if let machine, !Self.isResourceID(machine, prefix: "machine_") { return false }
        if let hostHint, !Self.isHint(hostHint) { return false }
        if let nameHint, !Self.isHint(nameHint) { return false }
        if let message, !Self.isAgentMessage(message) { return false }
        // Only an agent link carries hints; any other would not parse back the same.
        if hostHint != nil || nameHint != nil || message != nil, !target.isAgent { return false }
        switch target {
        case .workspace(let id): return Self.isResourceID(id, prefix: "ws_")
        case .pane(let id): return Self.isResourceID(id, prefix: "pane_")
        case .tab(let id): return Self.isResourceID(id, prefix: "tab_")
        case .session(let id, let turn): return Self.isToken(id) && (turn.map(Self.isToken) ?? true)
        case .chiefSession(let home, let session): return Self.isChiefHome(home) && Self.isToken(session)
        case .agent(let harness, let session): return Self.isHarness(harness) && Self.isAgentSession(session)
        case .group(let id, let workspace):
            return Self.isGroupID(id) && (workspace.map { Self.isResourceID($0, prefix: "ws_") } ?? true)
        case .legacyWorkspace, .legacyPane, .legacySurface: return true
        }
    }

    /// The hex digits after a resource id's prefix (128 bits).
    static let resourceHexDigits = 32
    /// The lengths a session or turn id may have.
    static let tokenLengths = 1...200
    /// The daemon's outside-harness session id bound and alphabet.
    static let agentSessionLengths = 1...256
    /// The lengths a harness name or a display hint may have.
    static let shortTokenLengths = 1...64

    /// `<prefix>` plus 128 bits as 32 lowercase hex digits
    /// (cmux-tui/spec/resource-api-v2.md).
    static func isResourceID(_ text: String, prefix: String) -> Bool {
        guard text.hasPrefix(prefix) else { return false }
        let hex = text.utf8.dropFirst(prefix.utf8.count)
        return hex.count == resourceHexDigits && hex.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    /// A cloud group id: `grp_` and 20 lowercase letters or digits, as TeamDO mints it
    /// (`ctx.newId("grp")`, backend packages/protocol team-group-ops.ts `GroupId`).
    static func isGroupID(_ text: String) -> Bool {
        guard text.hasPrefix("grp_") else { return false }
        let rest = text.utf8.dropFirst(4)
        return rest.count == 20 && rest.allSatisfy { (48...57).contains($0) || (97...122).contains($0) }
    }

    /// A Chief home id: 8 lowercase hex digits (FNV-1a 32 of the home's path).
    static func isChiefHome(_ text: String) -> Bool {
        text.utf8.count == 8 && text.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    /// An acpmux session or turn id: 1 to 200 ASCII letters, digits, `-`,
    /// `_` or `.`. Nothing that needs escaping in a URL.
    static func isToken(_ text: String) -> Bool {
        tokenLengths.contains(text.utf8.count) && text.utf8.allSatisfy { byte in
            (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
                || byte == UInt8(ascii: "-") || byte == UInt8(ascii: "_") || byte == UInt8(ascii: ".")
        }
    }

    /// An acpmux harness name (`claude`, `codex`, `opencode`): 1 to 64
    /// lowercase ASCII letters, digits or `-`.
    static func isHarness(_ text: String) -> Bool {
        shortTokenLengths.contains(text.utf8.count) && text.utf8.allSatisfy { byte in
            (48...57).contains(byte) || (97...122).contains(byte) || byte == UInt8(ascii: "-")
        }
    }

    /// A display hint (`?host=`, `?name=`): a token of at most 64 characters,
    /// not only dots.
    static func isHint(_ text: String) -> Bool {
        shortTokenLengths.contains(text.utf8.count) && isToken(text) && !isOnlyDots(text)
    }

    /// An agent link's harness session id. The daemon may publish `:` and up
    /// to 256 bytes; dots-only values are rejected because URL paths collapse
    /// `.` and `..`.
    static func isAgentSession(_ text: String) -> Bool {
        agentSessionLengths.contains(text.utf8.count) && !isOnlyDots(text)
            && text.utf8.allSatisfy { byte in
                (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
                    || byte == UInt8(ascii: "-") || byte == UInt8(ascii: "_")
                    || byte == UInt8(ascii: ".") || byte == UInt8(ascii: ":")
            }
    }

    /// Agent message ids retain the original token grammar.
    static func isAgentMessage(_ text: String) -> Bool {
        isToken(text) && !isOnlyDots(text)
    }

    static func isOnlyDots(_ text: String) -> Bool {
        text.utf8.allSatisfy { $0 == UInt8(ascii: ".") }
    }

    /// An RFC 3986 scheme: a letter, then letters, digits, `+`, `-` or `.`.
    static func isScheme(_ text: String) -> Bool {
        guard let first = text.utf8.first, (65...90).contains(first) || (97...122).contains(first) else { return false }
        return text.utf8.allSatisfy { byte in
            (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
                || byte == UInt8(ascii: "+") || byte == UInt8(ascii: "-") || byte == UInt8(ascii: ".")
        }
    }
}
