import AppKit
import CmuxNextAgentActivity
import CmuxNextPages
import CmuxNextSettings
import Foundation

extension InternalPageID {
    static let stats = InternalPageID(rawValue: "stats")
}

extension PageDescriptor {
    /// The Stats page (webviews/src/pages/stats, hq#1920): this computer's agent work, read only.
    /// Its one op `cmux.stats.summary` is relayed to the local acpmux, which folds its session logs;
    /// nothing leaves the machine.
    static let stats = PageDescriptor(id: "cmux.stats", resource: "stats", namespaces: ["cmux.stats."])
}

extension PageFactory {
    func statsWebPage() -> PageWebView? {
        let provider = StatsPageProvider(socket: { [weak services] in services.flatMap(QuitAgents.environment)?.socketPath })
        return PageWebView(descriptor: .stats, routes: [PageRoute(prefix: "cmux.stats.", provider: provider)])
    }
}

/// The Stats page as an internal page tab, one per window. A preview feature until styled
/// (`labs.previewFeatures`): ``StatsHandlers`` refuses `stats.show` without it.
@MainActor
final class StatsPageTab: InternalPageProvider {
    private weak var services: AppServices?
    private var pages: [String: PageWebView] = [:]

    init(services: AppServices) {
        self.services = services
    }

    var page: InternalPageID { .stats }
    var title: String { StatsStrings.title }
    var symbol: String { "chart.bar.xaxis" }

    func makeView(for key: String, in window: WindowController?) -> NSView {
        guard let services, let view = PageFactory(services: services).statsWebPage() else { return NSView() }
        pages[key] = view
        return view
    }

    func tabClosed(_ key: String) {
        pages.removeValue(forKey: key)?.close()
    }

    /// Opens (or selects) the Stats tab in the active window.
    @discardableResult
    static func open(_ services: AppServices) -> Bool {
        if services.pages.provider(.stats) == nil { services.pages.register(StatsPageTab(services: services)) }
        return services.pages.show(.stats, in: services.windows.active, focus: true) != nil
    }
}

/// `cmux.stats.summary {days, tzOffsetMinutes}`: one `_acpmux/stats` request on its own connection
/// to this app's acpmux, whose answer (counts and times only) goes back to the page as is.
@MainActor
final class StatsPageProvider: PageProvider {
    private let socket: @MainActor () -> String?

    init(socket: @escaping @MainActor () -> String?) {
        self.socket = socket
    }

    func call(_ op: String, params: CmuxNextSettings.JSONValue, context: PageCallContext) async throws -> CmuxNextSettings.JSONValue {
        guard op == "cmux.stats.summary" else { throw PageError.unknownOp(op) }
        guard let path = socket(), FileManager.default.fileExists(atPath: path) else {
            throw PageError(code: "cmux.stats.unavailable", message: StatsStrings.unavailable, retryable: true)
        }
        // Only the two numbers reach acpmux, which clamps them.
        var request: [String: CmuxNextSettings.JSONValue] = [:]
        if let days = params["days"]?.doubleValue { request["days"] = .number(days) }
        if let offset = params["tzOffsetMinutes"]?.doubleValue { request["tzOffsetMinutes"] = .number(offset) }
        let reply = try await Self.request(path: path, params: .object(request))
        if let message = reply["error"]?["message"]?.stringValue {
            throw PageError(code: "cmux.stats.failed", message: message, retryable: true)
        }
        guard let result = reply["result"] else {
            throw PageError(code: "cmux.stats.unavailable", message: StatsStrings.unavailable, retryable: true)
        }
        return result
    }

    /// `initialize`, then the stats request; the reply to the second is the answer.
    nonisolated static func request(path: String, params: CmuxNextSettings.JSONValue) async throws -> CmuxNextSettings.JSONValue {
        let initialize: CmuxNextSettings.JSONValue = ["jsonrpc": "2.0", "id": 1, "method": "initialize",
            "params": ["protocolVersion": 1, "clientInfo": ["name": "cmux-next-stats", "version": "1"], "clientCapabilities": .object([:])]]
        let stats: CmuxNextSettings.JSONValue = ["jsonrpc": "2.0", "id": 2, "method": "_acpmux/stats", "params": params]
        let send = Data((initialize.compactText + "\n" + stats.compactText + "\n").utf8)
        let connection = AgentActivityLineConnection(path: path)
        let reply = StatsReply()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CmuxNextSettings.JSONValue, any Error>) in
                reply.continuation = continuation
                connection.start(send: send, onLine: { line in
                    guard let message = try? CmuxNextSettings.JSONValue.parse(line), message["id"]?.doubleValue == 2 else { return }
                    reply.finish(.success(message))
                    connection.cancel()
                }, onClose: {
                    reply.finish(.failure(PageError(code: "cmux.stats.unavailable", message: StatsStrings.unavailable, retryable: true)))
                })
            }
        } onCancel: {
            connection.cancel()
        }
    }
}

/// Resumes the stats request once: the reply line and the connection's close race.
private nonisolated final class StatsReply: @unchecked Sendable { // crash-allow: every field is read and written under `lock`
    private let lock = NSLock() // concurrency-allow: guards one optional swap, never held across an await or IO
    private var pending: CheckedContinuation<CmuxNextSettings.JSONValue, any Error>?

    var continuation: CheckedContinuation<CmuxNextSettings.JSONValue, any Error>? {
        get { lock.withLock { pending } }
        set { lock.withLock { pending = newValue } }
    }

    func finish(_ result: Result<CmuxNextSettings.JSONValue, any Error>) {
        let waiter = lock.withLock {
            defer { pending = nil }
            return pending
        }
        waiter?.resume(with: result)
    }
}

nonisolated enum StatsStrings {
    static var title: String { String(localized: "stats.tab.title", defaultValue: "Agent Stats", table: "Stats", bundle: .module) }
    static var unavailable: String {
        String(localized: "stats.unavailable", defaultValue: "The agent service is not running, so there is nothing to count yet.",
               table: "Stats", bundle: .module)
    }
    static var preview: String {
        String(localized: "stats.refusal.preview", defaultValue: "Agent Stats is a preview feature: turn on Show Preview Features in Settings.",
               table: "Stats", bundle: .module)
    }
}
