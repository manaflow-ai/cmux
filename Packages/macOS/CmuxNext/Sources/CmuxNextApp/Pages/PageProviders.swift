import AppKit
import CmuxNextActions
import CmuxNextDaemon
import CmuxNextPages
import CmuxNextSettings
import Foundation

/// The app's native UI ops for React pages (plans/cmux-next/react-pages.md 1.3):
/// `cmux.app.action.run` runs one of the page's allowed registry actions with origin `user` (the
/// page is a user surface; the action's own rules, such as destructive confirmation, still
/// apply), and `cmux.app.clipboard.write` writes the pasteboard.
@MainActor
final class AppPageNativeProvider: PageProvider {
    private unowned let services: AppServices
    private let page: PageDescriptor
    /// Runs a confirmed namespace op on the provider that owns its namespace.
    var forward: (@MainActor (_ op: String, _ params: CmuxNextSettings.JSONValue, _ context: PageCallContext) async throws -> CmuxNextSettings.JSONValue)?
    var presenter: any PageConfirmationPresenter = AlertPageConfirmationPresenter()
    /// The page view the sheet attaches to.
    var anchor: () -> NSView? = { nil }

    init(services: AppServices, page: PageDescriptor) {
        self.services = services
        self.page = page
    }

    func call(_ op: String, params: CmuxNextSettings.JSONValue, context: PageCallContext) async throws -> CmuxNextSettings.JSONValue {
        switch op {
        case PageNativeOp.actionRun:
            if let name = params["action"]?.stringValue, let kind = page.confirmedOps[name] {
                return try await runConfirmed(name, kind: kind, args: params["args"] ?? .object([:]), context: context)
            }
            guard let name = params["action"]?.stringValue, page.actions.contains(name) else {
                throw PageError(code: "cmux.app.action_refused", message: "\(params["action"]?.stringValue ?? "") is not an action of this page")
            }
            let id = ActionID(rawValue: name)
            let invocation = ActionInvocation(arguments: Self.arguments(params["args"], for: services.registry.descriptor(for: id)),
                                              origin: .user)
            return ["ran": .bool(services.registry.perform(id, invocation: invocation))]
        case PageNativeOp.clipboardWrite:
            guard let text = params["text"]?.stringValue else { throw PageError.invalidParams("text is required") }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            return .object([:])
        default:
            throw PageError.unknownOp(op)
        }
    }

    /// A confirmed op (``PageDescriptor/confirmedOps``): the native sheet, then the op as the user's
    /// own on the namespace's provider. A declined sheet answers `{confirmed: false}` (the Cloud
    /// page's contract), an approved one `{confirmed: true, value}`.
    private func runConfirmed(_ op: String, kind: PageConfirmation.Kind, args: CmuxNextSettings.JSONValue,
                              context: PageCallContext) async throws -> CmuxNextSettings.JSONValue {
        guard let forward else { throw PageError.unknownOp(op) }
        let labels = (args.objectValue ?? [:]).compactMapValues(\.stringValue)
        guard await presenter.confirm(.forOp(op, kind: kind, args: labels), anchor: anchor()) else { return ["confirmed": false] }
        let value = try await forward(op, args, PageCallContext(page: context.page, origin: "user", confirmed: true))
        return ["confirmed": true, "value": value]
    }

    /// The page's `args` object as typed action arguments, by the descriptor's schema.
    static func arguments(_ args: CmuxNextSettings.JSONValue?, for descriptor: ActionDescriptor?) -> [String: ActionValue] {
        guard case .object(let members)? = args else { return [:] }
        var out: [String: ActionValue] = [:]
        for (name, value) in members {
            let kind = descriptor?.arguments.first { $0.name == name }?.kind
            switch (kind, value) {
            case (.bool?, .bool(let flag)): out[name] = .bool(flag)
            case (.int?, .number(let number)): out[name] = .int(Int(number))
            case (_, .string(let text)): out[name] = .string(text)
            case (_, .bool(let flag)): out[name] = .bool(flag)
            case (_, .number(let number)): out[name] = .int(Int(number))
            default: continue
            }
        }
        return out
    }
}

/// Relays a page's namespace to the local daemon (react-pages.md 1.1): `cmux.<ns>.<verb>` is the
/// daemon's v2 op `<ns>.<verb>` (decision ONE-CATALOG: the short wire name is the canonical name's
/// alias). `idempotency_key` moves from params to the v2 envelope; the daemon's refusal codes come
/// back under `cmux.`. Until the pane-protocol router is in the daemon, this relay is the data path.
@MainActor
final class DaemonPageRelay: PageProvider {
    private unowned let services: AppServices

    init(services: AppServices) {
        self.services = services
    }

    func call(_ op: String, params: CmuxNextSettings.JSONValue, context: PageCallContext) async throws -> CmuxNextSettings.JSONValue {
        guard op.hasPrefix("cmux.") else { throw PageError.unknownOp(op) }
        guard let connection = services.machines.local.connection else {
            throw PageError.closed
        }
        var members = params.objectValue ?? [:]
        let key = members.removeValue(forKey: "idempotency_key")?.stringValue
        do {
            let result = try await ResourceRelayClient(connection: connection).send(
                operation: String(op.dropFirst("cmux.".count)), params: try Self.daemonParams(members), idempotencyKey: key)
            return try Self.pageValue(result)
        } catch let error as DaemonError {
            throw Self.pageError(error)
        }
    }

    static func daemonParams(_ members: [String: CmuxNextSettings.JSONValue]) throws -> [String: CmuxNextDaemon.JSONValue] {
        try JSONDecoder().decode([String: CmuxNextDaemon.JSONValue].self,
                                 from: Data(CmuxNextSettings.JSONValue.object(members).compactText.utf8))
    }

    static func pageValue(_ value: CmuxNextDaemon.JSONValue) throws -> CmuxNextSettings.JSONValue {
        try CmuxNextSettings.JSONValue.parse(JSONEncoder().encode(value))
    }

    static func pageError(_ error: DaemonError) -> PageError {
        switch error {
        case .command(_, let message, let code, let details, let retryable):
            let pageCode = code.map { $0.hasPrefix("cmux.") ? $0 : "cmux." + $0 } ?? "cmux.daemon.failed"
            return PageError(code: pageCode, message: message, retryable: retryable ?? false,
                             details: details.flatMap { try? pageValue($0) })
        case .notConnected, .connectionClosed, .daemonShutdown:
            return PageError(code: "cmux.protocol.closed", message: error.description, retryable: true)
        case .timedOut:
            return PageError(code: "cmux.protocol.timeout", message: error.description, retryable: true)
        default:
            return PageError(code: "cmux.daemon.failed", message: error.description)
        }
    }
}

/// A namespace whose owner is not running yet: every call answers `code` (the page shows "Not
/// available yet" for it, never an error banner).
@MainActor
final class UnavailablePageProvider: PageProvider {
    private let code: String

    init(code: String) {
        self.code = code
    }

    func call(_ op: String, params: CmuxNextSettings.JSONValue, context: PageCallContext) async throws -> CmuxNextSettings.JSONValue {
        throw PageError(code: code, message: "\(op) is not available yet")
    }
}

extension AppServices {
    /// The React History page when Debug Settings `history.surface` is `web`, else nil (the
    /// Swift page). The tunable goes when the React page becomes the default (react-pages.md H3).
    func historyWebPage() -> PageWebView? {
        guard PageTunables.history.value == .web,
              let page = PageWebView(descriptor: .history, routes: pageRoutes(for: .history)) else { return nil }
        PageConnectionWatch(page: page, store: machines.local.store).start()
        return page
    }

    /// The Cloud app page (cmux.cloud) with the machine list layout from Debug Settings. Its
    /// namespace answers "not available yet" until the app supervisor (apps-v1) runs the Cloud app
    /// server; then the route goes to the supervisor relay.
    func cloudWebPage() -> PageWebView? {
        let native = AppPageNativeProvider(services: self, page: .cloud)
        let cloud = UnavailablePageProvider(code: "cmux.cloud.unsupported")
        native.forward = { op, params, context in try await cloud.call(op, params: params, context: context) }
        let routes = [PageRoute(prefix: "cmux.cloud.", provider: cloud), PageRoute(prefix: "cmux.app.", provider: native)]
        let page = PageWebView(descriptor: .cloud, routes: routes,
                               documentAttributes: ["cloud-machines-layout": PageTunables.cloudMachinesLayout.value.rawValue])
        native.anchor = { [weak page] in page }
        if let page { PageConnectionWatch(page: page, store: machines.local.store).start() }
        return page
    }

    /// The routes of `page`: its namespaces to the daemon relay, `cmux.app.` to the native ops
    /// (whose confirmed ops run on the namespace relay after the sheet).
    func pageRoutes(for page: PageDescriptor) -> [PageRoute] {
        let relay = DaemonPageRelay(services: self)
        let native = AppPageNativeProvider(services: self, page: page)
        native.forward = { op, params, context in try await relay.call(op, params: params, context: context) }
        return page.namespaces.map { PageRoute(prefix: $0, provider: relay) } + [PageRoute(prefix: "cmux.app.", provider: native)]
    }
}
