import Foundation
import CmuxNextCompat

/// The page relay's handshake (request-origin.md): `identify`, then `client-hello {role:
/// page_relay}` only when the daemon has `origin-claim-v1`, and no label. When the hello names
/// events the page hears (`page-events-v1`), a plain `subscribe` follows: the daemon narrows that
/// stream to those events, and the connection reports each one as it came (``DaemonEvent/raw``),
/// so the relay forwards it without a Swift type per event. The connection is ready, and takes page calls, only after the hello result: a
/// relay request never goes out with a client role. Without the capability the connect fails.
/// Its own type, not a `DaemonConnection` member (that type's line budget is frozen).
enum PageRelayHandshake {
    static func run(_ transport: LineTransport, configuration: DaemonConnectionConfiguration) async throws -> DaemonIdentity {
        let timeout = configuration.requestTimeout
        let first = await transport.pipeline([PipelinedLine(IdentifyRequest())], timeout: timeout)
        let identity = try WireCoding.decodeResponse(IdentifyRequest.Response.self, from: first[0].get().line)
        guard identity.app == "cmux-tui", identity.protocolVersion == 12 else {
            transport.close()
            throw identity.app == "cmux-tui" ? DaemonError.unsupportedProtocol(identity.protocolVersion) : DaemonError.wrongApp(identity.app)
        }
        guard identity.supports(DaemonClientRole.originClaimCapability) else {
            transport.close()
            throw DaemonError.missingCapabilities([DaemonClientRole.originClaimCapability])
        }
        // The page this relay serves, only to a daemon that knows page ids (an older one would
        // refuse nothing but apply no page list).
        let page = identity.supports(DaemonClientRole.pageRouterCapability) ? configuration.relayIdentity?.page : nil
        let request = ClientHelloRequest(role: .pageRelay, page: page)
        let hello = await transport.pipeline([PipelinedLine(request)], timeout: timeout)
        do {
            let reply = try WireCoding.decodeResponse(ClientHelloRequest.Response.self, from: hello[0].get().line)
            configuration.relayIdentity?.connectionID = reply.connectionId
            configuration.relayIdentity?.gestureOperations = Set(reply.pageOperations?.gesture ?? [])
            var events = Set(reply.pageEvents ?? [])
            if !events.isEmpty {
                // A refused or failed subscribe leaves the page without live events, never
                // without its calls.
                let subscribed = await transport.pipeline([PipelinedLine(SubscribeRequest(treeEvents: .coarse))], timeout: timeout)
                if (try? WireCoding.decodeResponse(EmptyResponse.self, from: subscribed[0].get().line)) == nil { events = [] }
            }
            configuration.relayIdentity?.events = events
            return identity
        } catch {
            transport.close()
            throw error
        }
    }
}

/// The page relay connection's daemon id from `client-hello` (a confirmation token is bound to it),
/// shared between the connection's handshake and the relay that issues tokens, with the page it
/// serves and that page's gesture operations from the hello reply (`page-router-v1`).
public final class PageRelayIdentity: Sendable {
    private let value = Mutex<String?>(nil)
    private let gestures = Mutex<Set<String>>([])
    private let pageEvents = Mutex<Set<String>>([])
    /// The page id (`history`), or nil for a relay that serves no one page.
    public let page: String?

    public init(page: String? = nil) {
        self.page = page
    }

    public var connectionID: String? {
        get { value.withLock { $0 } }
        set { value.withLock { $0 = newValue } }
    }

    /// The subscribe events the page hears on this relay (`history-changed`).
    public var events: Set<String> {
        get { pageEvents.withLock { $0 } }
        set { pageEvents.withLock { $0 = newValue } }
    }

    /// The operations the page may call only on the person's gesture.
    public var gestureOperations: Set<String> {
        get { gestures.withLock { $0 } }
        set { gestures.withLock { $0 = newValue } }
    }
}

/// What one page may call (cmux-tui/spec/page-router.json `pages`): reads freely, `gesture`
/// operations on the person's own key or pointer event, `confirm` operations after a native sheet.
/// The daemon enforces its own copy on a page relay; the app uses ``spec`` only where nothing
/// narrows the calls (a daemon without `origin-claim-v1`). PageRouterSpecTests keeps it equal to the spec.
public struct PageOperations: Sendable, Equatable {
    public let read: Set<String>
    public let gesture: Set<String>
    public let confirm: Set<String>

    public static let spec: [String: PageOperations] = [
        "agent": PageOperations(read: ["agent_session.trust.get"],
                              gesture: ["agent_session.trust.set"], confirm: []),
        "apps": PageOperations(read: ["apps.asset.get", "apps.catalog.get", "apps.catalog.list", "apps.grants.get", "apps.installed.list", "apps.logs"],
                              gesture: ["apps.grant.revoke", "apps.hidden.set"], confirm: ["apps.grant.set", "apps.install", "apps.set", "apps.uninstall"]),
        "bookmarks": PageOperations(read: ["bookmarks.list", "bookmarks.search"],
                              gesture: ["bookmarks.apply"], confirm: []),
        "feed": PageOperations(read: ["feed.github.find_work", "feed.item.get", "feed.items.list", "feed.reports.read", "feed.view.read"],
                              gesture: ["feed.github.refresh", "feed.intent", "feed.reports.reply"], confirm: []),
        "history": PageOperations(read: ["history.entries.list", "history.visit.summaries"],
                              gesture: ["history.clear", "history.entries.remove", "history.site.remove"], confirm: []),
        "home-channels": PageOperations(read: ["chief.profile.avatar.get", "chief.profile.avatar.set", "chief.profile.get", "chief.profile.history", "chief.profile.list", "chief.profile.update", "palette.rank", "participant.avatar.get"],
                              gesture: ["chief.profile.create", "chief.profile.delete", "chief.profile.undo", "workspace.open_url"], confirm: []),
        "stash": PageOperations(read: ["stash.list"],
                              gesture: ["stash.import"], confirm: []),
        "tasks": PageOperations(read: ["tasks.snapshot"],
                              gesture: ["tasks.archive", "tasks.create", "tasks.delegate", "tasks.move", "tasks.update"], confirm: []),
    ]

    /// Whether `operation` may go out where nothing narrows it: a listed read always, a `gesture`
    /// operation when `confirmed` or `gesture()` spends the person's event, a `confirm` operation
    /// only when `confirmed`; anything else never.
    public func allowsUnnarrowed(_ operation: String, confirmed: Bool, gesture: () -> Bool) -> Bool {
        if read.contains(operation) { return true }
        if confirm.contains(operation) { return confirmed }
        return self.gesture.contains(operation) && (confirmed || gesture())
    }

    /// ``allowsUnnarrowed(_:confirmed:gesture:)`` for `page` (a relay page id); a page the spec
    /// does not list may call nothing.
    public static func allowsUnnarrowed(_ page: String?, _ operation: String, confirmed: Bool, gesture: () -> Bool) -> Bool {
        page.flatMap { spec[$0] }?.allowsUnnarrowed(operation, confirmed: confirmed, gesture: gesture) ?? false
    }
}

extension DaemonEvent {
    /// One subscribe-stream line as the daemon sent it (`.unknown` with its whole object): what a
    /// page relay connection reports, so the relay forwards events without a Swift type for each.
    static func raw(name: String, line: Data) -> DaemonEvent {
        .unknown(name: name, payload: (try? WireCoding.decoder().decode(JSONValue.self, from: line)) ?? .null)
    }
}
