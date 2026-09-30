public import Foundation

/// A JSON parameter value of a relayed request.
public indirect enum RelayValue: Hashable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case array([RelayValue])
    case object([String: RelayValue])
    case null
}

/// What a remote machine may make this Mac do
/// (skills/cmux-socket-policy/references/remote-relay-authorization.md).
///
/// SSH machines add no relay: the app dials the remote daemon; the remote
/// host never gets a connection back to this Mac. The ssh the app runs
/// turns agent, X11 and port forwarding off (`SSHCommandLine`), the link
/// installs no agent hooks, and nothing remote reaches the app's control
/// socket. The only remote-originated input is the daemon's own tree and
/// events, which the app renders. This type is the gate any future relay
/// must use, and ``remoteBrowserURL(_:)`` is the one gate on remote tree
/// data that would open content locally.
///
/// Rules: deny unless the method is allowlisted; methods that run commands,
/// type input, spawn or respawn terminals, evaluate scripts or open URLs
/// can never be allowlisted; command-bearing params are denied on every
/// method; every workspace, surface and tab id param (arrays and
/// `*_workspace_id`-shaped names included) must name an object the remote
/// session owns, and ref forms never resolve.
public struct RemoteRelayPolicy: Sendable {
    /// Objects the remote session owns (its own daemon's tree).
    public struct Ownership: Sendable {
        public var workspaces: Set<String>
        public var surfaces: Set<String>
        public var tabs: Set<String>

        public init(workspaces: Set<String> = [], surfaces: Set<String> = [], tabs: Set<String> = []) {
            self.workspaces = workspaces
            self.surfaces = surfaces
            self.tabs = tabs
        }
    }

    public enum Denial: Hashable, Sendable {
        case notAllowlisted(String)
        case commandParam(String)
        case unownedTarget(String, String)
    }

    public enum Decision: Hashable, Sendable {
        case allow
        case deny(Denial)
    }

    /// Methods a relay may forward. Empty today: no remote flow needs one.
    public let allowed: Set<String>

    public static let denyAll = RemoteRelayPolicy(allowed: [])

    /// Params that carry a command line.
    public static let commandParams: Set<String> = ["initial_command", "command", "tmux_start_command", "pane_start_command"]

    /// Method words that execute, type, evaluate or open content locally;
    /// a method containing one is dropped from any allowlist.
    static let neverAllowedWords: Set<String> = ["send", "text", "key", "keys", "input", "paste", "spawn", "respawn", "eval", "exec",
                                                 "run", "script", "command", "url", "navigate", "resume", "launch"]
    /// Creating or splitting one of these starts a terminal or loads a page.
    static let spawningNouns: Set<String> = ["workspace", "tab", "pane", "surface", "terminal", "browser", "window", "screen", "column"]
    static let spawningVerbs: Set<String> = ["create", "new", "split", "open", "duplicate", "fork", "reopen", "move"]

    public init(allowed: Set<String>) {
        self.allowed = allowed.filter { !Self.isNeverAllowed($0) }
    }

    public func decide(method: String, params: [String: RelayValue], owned: Ownership) -> Decision {
        guard allowed.contains(method) else { return .deny(.notAllowlisted(method)) }
        for key in params.keys.sorted() where Self.commandParams.contains(key) {
            return .deny(.commandParam(key))
        }
        for key in params.keys.sorted() {
            guard let kind = Self.idKind(key) else { continue }
            let owners: Set<String> = switch kind {
            case .workspace: owned.workspaces
            case .surface: owned.surfaces
            case .tab: owned.tabs
            }
            for id in Self.strings(params[key]!) where !owners.contains(id) {
                return .deny(.unownedTarget(key, id))
            }
        }
        return .allow
    }

    /// The URL a browser record from a remote machine's tree may load here:
    /// web pages and `about:blank` only. `file:`, `javascript:`, `data:`,
    /// app schemes and every other scheme would open local content or
    /// launch local apps on the remote machine's say-so.
    public static func remoteBrowserURL(_ text: String?) -> URL? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty,
              let url = URL(string: text), let scheme = url.scheme?.lowercased() else { return nil }
        switch scheme {
        case "http", "https": return url.host?.isEmpty == false ? url : nil
        case "about": return text.lowercased() == "about:blank" ? url : nil
        default: return nil
        }
    }

    enum IDKind { case workspace, surface, tab }

    static func idKind(_ key: String) -> IDKind? {
        let lower = key.lowercased()
        let base = lower.hasSuffix("_ids") ? String(lower.dropLast(4)) : lower.hasSuffix("_id") ? String(lower.dropLast(3)) : nil
        guard let base else { return nil }
        if base == "workspace" || base.hasSuffix("_workspace") { return .workspace }
        if base == "surface" || base.hasSuffix("_surface") || base == "terminal" || base.hasSuffix("_terminal") { return .surface }
        if base == "tab" || base.hasSuffix("_tab") || base == "pane" || base.hasSuffix("_pane") { return .tab }
        return nil
    }

    static func strings(_ value: RelayValue) -> [String] {
        switch value {
        case .string(let text): [text]
        case .array(let items): items.flatMap(strings)
        case .number(let number): [String(number)]
        default: []
        }
    }

    static func isNeverAllowed(_ method: String) -> Bool {
        let words = Set(method.lowercased().split { !$0.isLetter }.map(String.init))
        if !words.isDisjoint(with: neverAllowedWords) { return true }
        return !words.isDisjoint(with: spawningNouns) && !words.isDisjoint(with: spawningVerbs)
    }
}
