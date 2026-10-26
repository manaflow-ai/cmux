import AppKit
import CmuxNextActions
import CmuxNextDaemon
import CmuxNextPages
import CmuxNextSettings
import Foundation

extension PageDescriptor {
    /// The memory inspector of a Chief on a paired server
    /// (plans/cmux-next/optchat-inspector.md, "Remote brains"):
    /// cmux-page://cmux.chief-inspector/. The same React page as the local
    /// inspector; it calls only `cmux.chief_inspector.get`, which the app
    /// relays to the brain's daemon (`chief-inspect`). No registry action,
    /// no native op.
    static let chiefInspector = PageDescriptor(
        id: "cmux.chief-inspector", resource: "chief-inspector", processGroup: .viewer, namespaces: ["cmux.chief_inspector."],
        opTables: [PageOpTable(namespace: "cmux.chief_inspector.", read: ["get"])])
}

extension InternalPageID {
    static let chiefInspector = InternalPageID(rawValue: "chief-inspector")
}

/// Owns the remote memory inspector's page tab. Its one op goes to the
/// paired server's brain daemon over the owner session the app holds (no
/// HTTP listener, no token on the link); the daemon answers only that owner.
@MainActor
final class ChiefInspectorPageService: InternalPageProvider {
    private weak var services: AppServices?
    /// The server whose Chief the latest open asked for (a tab restored at launch takes it).
    private(set) var machineID: String?
    /// The server each tab with no view yet was opened for, by tab key.
    private var openedFor: [String: String] = [:]

    init(services: AppServices) {
        self.services = services
    }

    var page: InternalPageID { .chiefInspector }
    var title: String { ChiefInspectorStrings.pageTitle }
    var symbol: String { "brain" }

    /// Shows the page for the Chief on `machineID` in `window`.
    func open(machineID: String, in window: WindowController, focus: Bool) -> Bool {
        self.machineID = machineID
        guard let view = services?.pages.show(.chiefInspector, in: window, focus: focus) else { return false }
        // A tab inspects the server it was opened for, not the one asked for when it first shows.
        if !view.isBuilt, openedFor[view.key] == nil { openedFor[view.key] = machineID }
        return true
    }

    func makeView(for key: String, in window: WindowController?) -> NSView {
        // Each tab keeps the server it was opened for; a tab restored at
        // launch (no open request yet) takes the first server that serves
        // chief-inspect.
        let opened = openedFor.removeValue(forKey: key) ?? machineID
        let provider = ChiefInspectorPageProvider { [weak self] in
            guard let machines = self?.services?.machines else { return nil }
            let server = opened.flatMap(machines.server)
                ?? machines.servers.first { $0.daemon.supports(DaemonCapability.chiefInspect.rawValue) }
            return server?.daemon.connection
        }
        let routes = [PageRoute(prefix: "cmux.chief_inspector.", provider: provider)]
        return services?.webUI.open(PageOpenRequest(descriptor: .chiefInspector, routes: routes)) ?? NSView()
    }

    func tabClosed(_ key: String) { openedFor[key] = nil }
}

/// `cmux.chief_inspector.get {path, query}`: one read-only inspector call,
/// relayed to the brain's daemon. Only the seven API paths pass (the daemon
/// and the brain check them again).
@MainActor
final class ChiefInspectorPageProvider: PageProvider {
    static let get = "cmux.chief_inspector.get"
    static let paths: Set<String> = [
        "/api/status", "/api/turns", "/api/turn", "/api/node", "/api/level", "/api/date", "/api/search",
    ]
    private let connection: @MainActor () -> DaemonConnection?

    init(connection: @escaping @MainActor () -> DaemonConnection?) {
        self.connection = connection
    }

    func call(_ op: String, params: CmuxNextSettings.JSONValue, context: PageCallContext) async throws
        -> CmuxNextSettings.JSONValue {
        guard op == Self.get else { throw PageError.unknownOp(op) }
        guard case .object(let fields) = params, case .string(let path)? = fields["path"], Self.paths.contains(path) else {
            throw PageError.invalidParams("path must be one of the inspector's API paths")
        }
        var query: [String: String] = [:]
        if case .object(let pairs)? = fields["query"] {
            for (key, value) in pairs {
                if case .string(let text) = value { query[key] = text }
            }
        }
        guard let connection = connection() else { throw PageError.unavailable(ChiefInspectorStrings.serverOffline) }
        let answer = try await connection.request(ChiefInspectRequest(path: path, query: query))
        guard answer.status == 200, let body = answer.body else {
            throw PageError(code: "cmux.chief_inspector.status_\(answer.status)", message: answer.error ?? "HTTP \(answer.status)")
        }
        return try CmuxNextSettings.JSONValue.parse(JSONEncoder().encode(body))
    }
}
