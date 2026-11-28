import Foundation
#if canImport(OSLog)
import OSLog
#endif
#if os(iOS)
import CmuxMobileLinkFFI
#endif

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
/// created or run. Parsing is Rust's; this keeps the values the app routes by.
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
        /// A Mac's screen through the device hub (`mac-screen?device=&display=&control=1&name=`,
        /// web `cmux.com/deeplink/screen?…`): view only unless the link asks for control.
        case macScreen(MacScreenLink)
    }

    /// A Mac screen link: the hub device to view, the display on it, and whether it asks for control.
    public struct MacScreenLink: Hashable, Sendable {
        /// The hub device id (lowercase uuid).
        public var device: String
        /// The CGDirectDisplayID in decimal; nil is whatever the host streams by default.
        public var display: String?
        /// `control=1`: ask for Full Control; otherwise the session is View Only.
        public var control: Bool
        /// The run's label (display only, never used to route).
        public var name: String?

        public init(device: String, display: String? = nil, control: Bool = false, name: String? = nil) {
            self.device = device
            self.display = display
            self.control = control
            self.name = name
        }
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
        case .macScreen: "mac-screen"
        }
    }
    /// An agent link's `?message=`: the message to scroll to (display only).
    public var message: String?

    public init(_ target: Target, message: String? = nil) {
        self.target = target
        self.message = message
    }

    /// The link `url` names, or nil when it is not a cmux link (another
    /// scheme or host, the sign-in callback, a malformed id). The grammar is
    /// Rust's (`cmux-mobile-link-ffi/src/cmux_link.rs`); where Rust does not
    /// link (the macOS and Linux package builds, which have no phone UI) no
    /// URL is a cmux link.
    public init?(url: URL) {
        #if os(iOS)
        guard let parsed = cmuxLinkParse(url: url.absoluteString) else { return nil }
        self.init(Self.target(parsed.target), message: parsed.message)
        #else
        return nil
        #endif
    }

    /// Whether `scheme` is a cmux build's link scheme. `cmux-next` is never a link.
    /// Kept in Swift: ``ChatShareLink`` reads it on every platform, and the macOS/Linux package
    /// builds have no Rust (step B, #58735).
    public static func isLinkScheme(_ scheme: String) -> Bool {
        let scheme = scheme.lowercased()
        return ["cmux", "cmux-nightly", "cmux-rc", "cmux-dev"].contains(scheme) || scheme.hasPrefix("cmux-dev-")
    }

    /// The hosts whose https links the phone opens.
    public static let webHosts: Set<String> = ["cmux.com", "www.cmux.com"]

    #if os(iOS)
    private static func target(_ target: CmuxLinkTarget) -> Target {
        switch target {
        case let .workspace(id): .workspace(id)
        case let .pane(id): .pane(id)
        case let .tab(id): .tab(id)
        case let .session(id, turn): .session(id, turn: turn)
        case let .chiefSession(home, session): .chiefSession(home: home, session: session)
        case let .agent(harness, session): .agent(harness: harness, session: session)
        case let .group(id, workspace): .group(id, workspace: workspace)
        case let .conversation(id, message): .conversation(id, message: message)
        case let .macScreen(device, display, control, name):
            .macScreen(MacScreenLink(device: device, display: display, control: control, name: name))
        }
    }
    #endif
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
