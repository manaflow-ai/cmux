public import CmuxNextDaemon
public import CmuxNextSettings
import Foundation
import Synchronization

/// The old `cmux` CLI's v2 methods on top of cmux-tui and the App
/// (plans/cmux-next/cli-compat.md). Layout and terminal verbs forward to the
/// daemon; windows, focus, selection, and browser pages go to the App's
/// `CompatFrontend`; everything else answers a typed `unsupported` error.
///
/// Runs entirely off the main actor: reads fetch `list-workspaces` from the
/// daemon (read-your-writes for scripts) joined with the App's published
/// frontend snapshot; daemon mutations go straight to the daemon, which is
/// the serialization point; frontend intents hop through the App's queue
/// with a deadline.
public final class CompatService: ControlMethodProvider {
    public typealias ConnectionProvider = @Sendable () async -> DaemonConnection?

    let connectionProvider: ConnectionProvider
    let frontend: any CompatFrontend
    let refs = CompatRefRegistry()
    let sidebar = CompatSidebarStore()
    let identity: ControlIdentity
    /// cmux keys every terminal this app spawns gets (`LaunchIdentity.terminalEnvironment`).
    let terminalEnvironment: [String: String]
    /// Set by `install(on:)`; used for `system.identify` transport fields.
    private let routerRef = Mutex(WeakRouter())

    var router: ControlRouter? { routerRef.withLock { $0.router } }

    public init(identity: ControlIdentity, frontend: any CompatFrontend, terminalEnvironment: [String: String] = [:],
                connection: @escaping ConnectionProvider) {
        self.identity = identity
        self.terminalEnvironment = terminalEnvironment
        self.frontend = frontend
        self.connectionProvider = connection
    }

    /// Registers on `router` (the registration seam).
    public func install(on router: ControlRouter) {
        routerRef.withLock { $0.router = router }
        router.register(self)
    }

    // MARK: - ControlMethodProvider

    public var methods: [String] { Self.handlers.keys.sorted() }

    public func claims(_ method: String) -> Bool {
        if Self.handlers[method] != nil { return true }
        return CompatUnsupported.reason(for: method) != nil
    }

    public func handle(_ request: ControlRequest) async throws -> CmuxNextSettings.JSONValue {
        if let handler = Self.handlers[request.method] {
            return try await handler(CompatCall(service: self, method: request.method, params: request.params))
        }
        let reason = CompatUnsupported.reason(for: request.method) ?? "not implemented"
        throw CompatErrors.unsupported(reason, method: request.method)
    }

    public func respondV1(_ line: String) async -> String? {
        await CompatV1.respond(line, service: self)
    }

    static let handlers: [String: CompatHandler] = {
        var all: [String: CompatHandler] = [:]
        for table in [CompatSystemMethods.table, CompatWorkspaceMethods.table, CompatPaneMethods.table,
                      CompatSurfaceMethods.table, CompatTerminalMethods.table, CompatNotificationMethods.table,
                      CompatAgentMethods.table, CompatBrowserMethods.table] {
            all.merge(table) { first, _ in first }
        }
        return all
    }()

    // MARK: - Shared plumbing

    func connection() async throws -> DaemonConnection {
        guard let connection = await connectionProvider(), await connection.isReady else { throw CompatErrors.notConnected }
        return connection
    }

    /// Runs one daemon command with the control-plane deadline and maps errors.
    func daemon<T: Sendable>(_ what: String, _ body: @escaping @Sendable (DaemonConnection) async throws -> T) async throws -> T {
        let connection = try await connection()
        do {
            return try await CompatDeadline.run(what) { try await body(connection) }
        } catch {
            throw CompatErrors.from(error, doing: what)
        }
    }

    /// A fresh world: `list-workspaces` joined with the frontend snapshot.
    func world() async throws -> CompatWorld {
        let tree = try await daemon("list-workspaces") { try await $0.listWorkspaces() }
        return CompatWorld(tree: tree, frontend: frontend.snapshot(), refs: refs)
    }

    /// Runs an App intent with a deadline.
    @discardableResult
    func perform(_ intent: CompatFrontendIntent, within limit: Duration = CompatDeadline.controlPlane) async throws -> CmuxNextSettings.JSONValue {
        let frontend = frontend
        do {
            return try await CompatDeadline.run("app \(Self.label(intent))", within: limit) { try await frontend.perform(intent) }
        } catch let error as ControlError {
            throw error
        } catch {
            throw ControlError(code: "app_error", message: String(describing: error))
        }
    }

    static func label(_ intent: CompatFrontendIntent) -> String {
        switch intent {
        case .showWorkspace: "show-workspace"
        case .focusPane: "focus-pane"
        case .selectTab: "select-tab"
        case .newWindow: "new-window"
        case .focusWindow: "focus-window"
        case .closeWindow: "close-window"
        case .browser: "browser"
        }
    }
}

struct WeakRouter: Sendable {
    weak var router: ControlRouter?
}

typealias CompatHandler = @Sendable (CompatCall) async throws -> JSON

/// One request as a handler sees it.
struct CompatCall: Sendable {
    let service: CompatService
    let method: String
    let params: [String: JSON]

    func world() async throws -> CompatWorld { try await service.world() }
    func target(_ world: CompatWorld) -> CompatTarget { CompatTarget(world: world, refs: service.refs, params: params) }

    func string(_ key: String) -> String? {
        guard let value = params[key], !value.isNull else { return nil }
        return value.stringValue ?? value.compactText
    }

    func bool(_ key: String) -> Bool? {
        guard let value = params[key] else { return nil }
        if let flag = value.boolValue { return flag }
        switch value.stringValue?.lowercased() {
        case "1", "true", "yes", "on": return true
        case "0", "false", "no", "off": return false
        default: return value.intValue.map { $0 != 0 }
        }
    }

    func int(_ key: String) -> Int? {
        params[key]?.intValue ?? params[key]?.stringValue.flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
    }

    func require(_ key: String) throws -> String {
        guard let value = string(key), !value.isEmpty else { throw CompatErrors.missing(key, method) }
        return value
    }

    /// Old-app `focus` param: default false for creation verbs (no focus steal).
    var wantsFocus: Bool { bool("focus") ?? false }
}
