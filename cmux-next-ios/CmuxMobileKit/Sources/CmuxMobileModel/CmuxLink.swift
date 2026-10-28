import Foundation
import OSLog

private let log = Logger(subsystem: "dev.cmux.mobile", category: "links")

/// A cmux link the phone opens: what the Mac copies (Copy Link), what Chief and
/// agents write in their text, and the https forms cmux.com and the Cloud
/// service hand out. The grammar is the Mac's (`CmuxNextActions/DeepLink`):
/// `<scheme>://<kind>/<id>`, where the id is the Mac's public resource id
/// (`ws_`, `pane_`, `tab_` and 32 lowercase hex digits), never a handle.
///
/// Schemes: every cmux build's (`cmux`, `cmux-nightly`, `cmux-rc`, `cmux-dev`,
/// `cmux-dev-<tag>`): the Chief writes `cmux` whatever the build, and a Mac
/// dev build copies its own. https: `cmux.com/deeplink/agent?harness=&session=`
/// (schemas/deeplinks/agent-link.json), a cloud group's
/// `/g/<grp_>[/w/<ws_>]` page, and `cmux.com/link/<kind>/…`, the same path as
/// the native link. A link is an address, never a command: every query
/// parameter but the ones named here is ignored, and nothing it names is
/// created or run.
public struct CmuxLink: Hashable, Sendable {
    public enum Target: Hashable, Sendable {
        /// A workspace by its `ws_` resource id.
        case workspace(String)
        /// A pane by its `pane_` resource id: its selected tab.
        case pane(String)
        /// A terminal, browser or agent tab by its `tab_` resource id.
        case tab(String)
        /// An acpmux chat session, optionally at one turn (`#turn-<id>`).
        case session(String, turn: String?)
        /// A Chief subagent's chat (`chief/<home>/session/<id>`).
        case chiefSession(home: String, session: String)
        /// An outside agent's session by the harness's own id (`agent/<harness>/<session>`).
        case agent(harness: String, session: String)
        /// A cloud group, optionally one of its workspaces.
        case group(String, workspace: String?)
        /// A Home conversation, optionally at one message (`conversation/<id>[/message/<id>]`).
        case conversation(String, message: String?)
    }

    public var target: Target

    /// The link's kind for logs (never its ids).
    public var kind: String {
        switch target {
        case .workspace: "workspace"
        case .pane: "pane"
        case .tab: "tab"
        case .session: "session"
        case .chiefSession: "chief"
        case .agent: "agent"
        case .group: "group"
        case .conversation: "conversation"
        }
    }
    /// An agent link's `?message=`: the message to scroll to (display only).
    public var message: String?

    public init(_ target: Target, message: String? = nil) {
        self.target = target
        self.message = message
    }

    /// The link `url` names, or nil when it is not a cmux link (another
    /// scheme or host, the sign-in callback, the pairing code, a malformed id).
    public init?(url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.user == nil, components.password == nil,
              let scheme = components.scheme?.lowercased() else { return nil }
        let query = components.queryItems ?? []
        if scheme == "https" {
            guard components.port == nil, let host = components.host?.lowercased(),
                  let link = Self.web(host: host, path: Self.segments(components.path), query: query) else { return nil }
            self = link
            return
        }
        guard Self.isLinkScheme(scheme), components.port == nil,
              let host = components.host?.lowercased(), !host.isEmpty,
              let link = Self.native(host: host, path: Self.segments(components.path), query: query, fragment: components.fragment)
        else { return nil }
        self = link
    }

    /// Whether `scheme` is a cmux build's link scheme. `cmux-next` is the
    /// pairing code's (PairInvite), never a link.
    public static func isLinkScheme(_ scheme: String) -> Bool {
        let scheme = scheme.lowercased()
        return ["cmux", "cmux-nightly", "cmux-rc", "cmux-dev"].contains(scheme) || scheme.hasPrefix("cmux-dev-")
    }

    /// The hosts whose https links the phone opens.
    public static let webHosts: Set<String> = ["cmux.com", "www.cmux.com"]
    /// The hosts that serve a cloud group's hand-off page (as the Mac's `DeepLink.groupWebHosts`).
    public static let groupWebHosts: Set<String> = ["cloud-api.cmux.dev", "cloud-api-staging.cmux.dev", "cmux.com", "www.cmux.com"]

    // MARK: Parsing

    private static func segments(_ path: String) -> [String] {
        path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    }

    private static func native(host: String, path: [String], query: [URLQueryItem], fragment: String?) -> CmuxLink? {
        guard let first = path.first else { return nil }
        switch host {
        case "workspace":
            guard path.count == 1, fragment == nil, isResourceID(first, prefix: "ws_") else { return nil }
            return CmuxLink(.workspace(first))
        case "pane":
            guard path.count == 1, fragment == nil, isResourceID(first, prefix: "pane_") else { return nil }
            return CmuxLink(.pane(first))
        case "tab":
            guard path.count == 1, fragment == nil, isResourceID(first, prefix: "tab_") else { return nil }
            return CmuxLink(.tab(first))
        case "session":
            guard path.count == 1, isToken(first) else { return nil }
            guard let fragment else { return CmuxLink(.session(first, turn: nil)) }
            guard fragment.hasPrefix("turn-"), isToken(String(fragment.dropFirst(5))) else { return nil }
            return CmuxLink(.session(first, turn: String(fragment.dropFirst(5))))
        case "chief":
            guard path.count == 3, path[1] == "session", fragment == nil, isChiefHome(first), isToken(path[2]) else { return nil }
            return CmuxLink(.chiefSession(home: first, session: path[2]))
        case "agent":
            guard path.count == 2, fragment == nil else { return nil }
            return agent(harness: first, session: path[1], query: query)
        case "group":
            guard fragment == nil, isGroupID(first) else { return nil }
            if path.count == 1 { return CmuxLink(.group(first, workspace: nil)) }
            guard path.count == 3, path[1] == "workspace", isResourceID(path[2], prefix: "ws_") else { return nil }
            return CmuxLink(.group(first, workspace: path[2]))
        case "conversation":
            guard isToken(first) else { return nil }
            if path.count == 1 { return CmuxLink(.conversation(first, message: nil)) }
            guard path.count == 3, path[1] == "message", isToken(path[2]) else { return nil }
            return CmuxLink(.conversation(first, message: path[2]))
        default:
            // Includes `auth-callback`, the sign-in callback.
            return nil
        }
    }

    private static func web(host: String, path: [String], query: [URLQueryItem]) -> CmuxLink? {
        var path = path
        if groupWebHosts.contains(host), path.count >= 2, path[0] == "g", isGroupID(path[1]) {
            if path.count == 2 { return CmuxLink(.group(path[1], workspace: nil)) }
            guard path.count == 4, path[2] == "w", isResourceID(path[3], prefix: "ws_") else { return nil }
            return CmuxLink(.group(path[1], workspace: path[3]))
        }
        guard webHosts.contains(host) else { return nil }
        // cmux.com's locale prefix (`/en/deeplink/agent`).
        if let first = path.first, first.count == 2 || (first.count == 5 && first.contains("-")), path.count > 1,
           ["deeplink", "link"].contains(path[1]) {
            path.removeFirst()
        }
        if path == ["deeplink", "agent"] {
            func value(_ name: String) -> String? {
                let items = query.filter { $0.name == name }
                return items.count == 1 ? items[0].value : nil
            }
            guard let harness = value("harness"), let session = value("session") else { return nil }
            return agent(harness: harness, session: session, query: query)
        }
        // `cmux.com/link/<kind>/…` is the native link's path on the web.
        guard path.first == "link", path.count >= 3 else { return nil }
        return native(host: path[1], path: Array(path.dropFirst(2)), query: query, fragment: nil)
    }

    private static func agent(harness: String, session: String, query: [URLQueryItem]) -> CmuxLink? {
        guard isHarness(harness), isAgentSession(session) else { return nil }
        let messages = query.filter { $0.name == "message" }
        let message = messages.count == 1 ? messages[0].value.flatMap { isToken($0) && !isOnlyDots($0) ? $0 : nil } : nil
        return CmuxLink(.agent(harness: harness, session: session), message: message)
    }

    // MARK: Grammar (the Mac's DeepLink)

    static func isResourceID(_ text: String, prefix: String) -> Bool {
        guard text.hasPrefix(prefix) else { return false }
        let hex = text.utf8.dropFirst(prefix.utf8.count)
        return hex.count == 32 && hex.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    static func isGroupID(_ text: String) -> Bool {
        guard text.hasPrefix("grp_") else { return false }
        let rest = text.utf8.dropFirst(4)
        return rest.count == 20 && rest.allSatisfy { (48...57).contains($0) || (97...122).contains($0) }
    }

    static func isChiefHome(_ text: String) -> Bool {
        text.utf8.count == 8 && text.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    static func isToken(_ text: String) -> Bool {
        (1...200).contains(text.utf8.count) && text.utf8.allSatisfy { byte in
            (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
                || byte == UInt8(ascii: "-") || byte == UInt8(ascii: "_") || byte == UInt8(ascii: ".")
        }
    }

    static func isHarness(_ text: String) -> Bool {
        (1...64).contains(text.utf8.count) && text.utf8.allSatisfy { byte in
            (48...57).contains(byte) || (97...122).contains(byte) || byte == UInt8(ascii: "-")
        }
    }

    static func isAgentSession(_ text: String) -> Bool {
        (1...256).contains(text.utf8.count) && !isOnlyDots(text) && text.utf8.allSatisfy { byte in
            (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
                || byte == UInt8(ascii: "-") || byte == UInt8(ascii: "_")
                || byte == UInt8(ascii: ".") || byte == UInt8(ascii: ":")
        }
    }

    static func isOnlyDots(_ text: String) -> Bool {
        text.utf8.allSatisfy { $0 == UInt8(ascii: ".") }
    }
}

/// Hands a cmux link tapped anywhere in the app (a chat message, the Feed,
/// Chief) to the shell, which opens it in place instead of leaving the app.
@MainActor
public final class CmuxLinkOpener {
    public static let shared = CmuxLinkOpener()

    /// Set by the shell: opens a parsed link.
    public var handler: ((CmuxLink) -> Void)?

    public init() {}

    /// Opens `url` in the app when it is a cmux link; false (nothing happens)
    /// for any other URL, which the caller opens as before.
    @discardableResult
    public func open(_ url: URL) -> Bool {
        guard let link = CmuxLink(url: url) else { return false }
        guard let handler else {
            log.error("cmux link tapped before the shell could open it")
            return false
        }
        log.info("opening a cmux link: \(link.kind, privacy: .public)")
        handler(link)
        return true
    }
}
