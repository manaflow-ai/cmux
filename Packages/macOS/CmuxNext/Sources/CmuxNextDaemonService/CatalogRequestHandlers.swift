public import CmuxNextActions
public import CmuxNextAgentPane
public import CmuxNextControl
import CmuxNextDaemon
import Foundation

/// What the catalog request binder needs from the App: the connections a request goes on, the
/// daemon id of a target, and a toast. The App conforms with one-line forwards.
@MainActor
public protocol CatalogRequestHost: AnyObject {
    /// The session host a `session` request goes to (the active window's machine).
    var catalogDaemon: DaemonService { get }
    /// The app's own control router, for an `app` request; nil before it starts.
    var catalogControlRouter: ControlRouter? { get }
    /// This app's acpmux daemon, for an `acpmux` request; nil when there is none.
    func catalogAcpmux() async -> AcpmuxEnvironment?
    /// The daemon id of the invocation's workspace, else of the active window's.
    func catalogWorkspace(_ invocation: ActionInvocation) -> String?
    /// The daemon id of the invocation's pane, else of the focused one.
    func catalogPane(_ invocation: ActionInvocation) -> String?
    /// Shows `message` briefly on the active window.
    func catalogToast(_ message: String)
}

/// The catalog request rows (cmux-action-catalog `Action::request`): an action whose catalog row
/// names the one daemon request that runs it, sent here with no handler of its own, and the
/// `op:` suggestion sources answered by one list request. Bound once, after every other handler:
/// only a still-unbound action with a request gets this binding, so a hand-written handler
/// always wins.
///
/// Each run is `.applied(result:)`: on its turn it shows a toast with the action's title (the
/// visible change), and the request runs as the registry's result work; a failure comes back as
/// the action's failure. It never awaits on the turn. The operation names come only from the
/// compiled catalog, never from user config, and there is no CLI lane: nothing here starts a
/// process. A relayed run (another device, `ActionOrigin.remote`) is refused: default deny.
@MainActor
public struct CatalogRequestHandlers {
    let host: any CatalogRequestHost

    public init(host: any CatalogRequestHost) {
        self.host = host
    }

    public func bind(into registry: ActionRegistry) {
        let host = host
        for id in registry.unboundActionIDs() {
            guard let descriptor = registry.descriptor(for: id), let request = descriptor.catalogRequest else { continue }
            registry.bindEffect(id, effect: { invocation in
                Self.effect(request, descriptor: descriptor, invocation: invocation, host: host)
            })
        }
        installListSources(registry)
    }

    /// The question a destructive catalog request row asks before a keyboard, menu or palette
    /// run (the App's `DestructiveConfirmation` falls back to it): the row's own title, with a
    /// button that names the action. Nil for a row that names no request or is not destructive,
    /// so no destructive request row can run unasked because no hand-written question lists it.
    public static func confirmation(for descriptor: ActionDescriptor, request: ActionCatalogRequest? = nil)
        -> (title: String, body: String, button: String)? {
        guard descriptor.isDestructive, (request ?? descriptor.catalogRequest) != nil else { return nil }
        var button = descriptor.title
        while button.hasSuffix("…") || button.hasSuffix(".") { button.removeLast() }
        return (descriptor.title, CatalogRequestStrings.destructiveBody, button)
    }

    /// Why `invocation` may not send a catalog request, nil when it may.
    static func refusal(_ invocation: ActionInvocation) -> String? {
        invocation.origin == .remote ? CatalogRequestStrings.remote : nil
    }

    static func effect(_ request: ActionCatalogRequest, descriptor: ActionDescriptor, invocation: ActionInvocation,
                       host: any CatalogRequestHost) -> ActionEffect {
        if let reason = refusal(invocation) { return .refused(reason) }
        let resolved = request.values(arguments: descriptor.arguments, invocation: invocation) { kind in
            switch kind {
            case .workspace: host.catalogWorkspace(invocation)
            case .pane: host.catalogPane(invocation)
            default: nil
            }
        }
        let values: [String: ActionCatalogRequest.Value]
        switch resolved {
        case .success(let found): values = found
        case .failure(let missing):
            return .refused(missing.kind == .pane ? CatalogRequestStrings.noPane : RefusalStrings.noWorkspaceToActOn)
        }
        guard let work = send(request, values, host: host) else { return .refused(CatalogRequestStrings.notConnected) }
        host.catalogToast(descriptor.title)
        return .applied(result: work)
    }

    /// The request's work on its lane, nil when that lane's connection is not there.
    static func send(_ request: ActionCatalogRequest, _ values: [String: ActionCatalogRequest.Value],
                     host: any CatalogRequestHost) -> (@MainActor () async -> Result<[String: ActionResultValue], ActionWorkFailure>)? {
        let operation = request.operation
        switch request.lane {
        case .session:
            let daemon = host.catalogDaemon
            let params = values.mapValues(daemonJSON)
            return {
                do {
                    _ = try await daemon.perform(operation) { try await $0.catalogOperation(operation, params: params, mutation: true) }
                    return .success([:])
                } catch {
                    return .failure(ActionWorkFailure(String(describing: error)))
                }
            }
        case .app:
            guard let router = host.catalogControlRouter else { return nil }
            guard let control = controlRequest(operation, values) else { return nil }
            return {
                switch await router.handle(control) {
                case .success: return .success([:])
                case .failure(let error): return .failure(ActionWorkFailure(error.message))
                }
            }
        case .acpmux:
            let params = values.mapValues(sendable)
            return {
                guard let acpmux = await host.catalogAcpmux() else { return .failure(ActionWorkFailure(CatalogRequestStrings.notConnected)) }
                do {
                    _ = try await acpmux.catalogCall(operation, params: params)
                    return .success([:])
                } catch {
                    return .failure(ActionWorkFailure(String(describing: error)))
                }
            }
        }
    }

    // MARK: - op: suggestion sources

    /// Answers every `op:` suggestion source from its list request; any other source goes to the
    /// sources installed before. Each ask reads the list again (a closed item can be gone since)
    /// under the palette's loading state; the last answer stays for `argumentSuggestions`.
    private func installListSources(_ registry: ActionRegistry) {
        let lists = ActionCatalog.listSources
        guard !lists.isEmpty else { return }
        let host = host
        let loaded = LoadedLists()
        let otherSuggestions = registry.argumentSuggestions
        registry.argumentSuggestions = { source in
            guard lists[source] != nil else { return otherSuggestions?(source) ?? [] }
            return loaded.rows[source] ?? []
        }
        let otherLoad = registry.argumentSuggestionsLoad
        registry.argumentSuggestionsLoad = { source in
            guard let list = lists[source] else { return otherLoad?(source) ?? nil }
            guard let read = Self.read(list, host: host) else { return nil }
            return {
                let rows = await read()
                loaded.rows[source] = rows
                return rows
            }
        }
    }

    /// The last rows each `op:` source answered.
    @MainActor private final class LoadedLists {
        var rows: [String: [ActionEnumCase]] = [:]
    }

    /// The list request's rows as suggestions, nil when its lane is not there.
    static func read(_ list: ActionCatalogListSource, host: any CatalogRequestHost) -> (@MainActor () async -> [ActionEnumCase])? {
        let operation = list.operation
        let rows: @MainActor () async -> Data?
        switch list.lane {
        case .session:
            let daemon = host.catalogDaemon
            rows = {
                guard let value = try? await daemon.perform(operation, { try await $0.catalogOperation(operation, params: [:], mutation: false) })
                else { return nil }
                return try? JSONEncoder().encode(value)
            }
        case .app:
            guard let router = host.catalogControlRouter else { return nil }
            rows = {
                guard case .success(let value) = await router.handle(ControlRequest(method: operation)) else { return nil }
                return try? JSONEncoder().encode(value)
            }
        case .acpmux:
            rows = {
                guard let acpmux = await host.catalogAcpmux() else { return nil }
                return try? await acpmux.catalogCall(operation, params: [:])
            }
        }
        return { (await rows()).map { cases(from: $0, list) } ?? [] }
    }

    /// The suggestions a list result holds: the rows at `items` (else the result itself), each
    /// row's `value` field as the value and its `title` field as the title (the value when it
    /// has none). Rows without a value are skipped.
    nonisolated static func cases(from data: Data, _ list: ActionCatalogListSource) -> [ActionEnumCase] {
        guard let result = try? JSONSerialization.jsonObject(with: data) else { return [] }
        let rows = list.items.map { (result as? [String: Any])?[$0] } ?? result
        return (rows as? [[String: Any]] ?? []).compactMap { row in
            guard let value = text(row[list.value]), !value.isEmpty else { return nil }
            return ActionEnumCase(value: value, title: text(row[list.title]) ?? value)
        }
    }

    private nonisolated static func text(_ value: Any?) -> String? {
        switch value {
        case let text as String: text
        case let number as NSNumber: number.stringValue
        default: nil
        }
    }

    // MARK: - Wire values

    nonisolated static func daemonJSON(_ value: ActionCatalogRequest.Value) -> CmuxNextDaemon.JSONValue {
        switch value {
        case .string(let text): .string(text)
        case .int(let number): .number(Double(number))
        case .bool(let flag): .bool(flag)
        case .strings(let items): .array(items.map(CmuxNextDaemon.JSONValue.string))
        }
    }

    /// The app's control request for `operation` with `values`, nil when they do not encode. The
    /// params go through their JSON form: the control wire's value type is the settings one, which
    /// this service layer does not depend on.
    nonisolated static func controlRequest(_ operation: String, _ values: [String: ActionCatalogRequest.Value]) -> ControlRequest? {
        var request = ControlRequest(method: operation)
        guard let data = try? JSONEncoder().encode(values.mapValues(daemonJSON)),
              let params = try? JSONDecoder().decode(type(of: request.params), from: data) else { return nil }
        request.params = params
        return request
    }

    nonisolated static func sendable(_ value: ActionCatalogRequest.Value) -> any Sendable {
        switch value {
        case .string(let text): text
        case .int(let number): number
        case .bool(let flag): flag
        case .strings(let items): items
        }
    }
}

/// Refusals of a catalog request row (Resources/CatalogRequests.xcstrings).
struct CatalogRequestStrings {
    static var remote: String {
        String(localized: "catalogRequest.remote", defaultValue: "this action does not run from another device",
               table: "CatalogRequests", bundle: .localizedModule)
    }

    static var notConnected: String {
        String(localized: "catalogRequest.notConnected", defaultValue: "the service this action needs is not connected",
               table: "CatalogRequests", bundle: .localizedModule)
    }

    static var noPane: String {
        // retry-prompt-ok: refuses the person's own request until they pick a tab (their choice, no button)
        String(localized: "catalogRequest.noPane", defaultValue: "Click a tab first, then try again.", table: "CatalogRequests", bundle: .localizedModule)
    }

    static var destructiveBody: String {
        String(localized: "catalogRequest.destructiveBody", defaultValue: "This can't be undone.",
               table: "CatalogRequests", bundle: .localizedModule)
    }
}
