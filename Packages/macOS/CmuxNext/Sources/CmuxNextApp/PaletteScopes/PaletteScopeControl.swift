import CmuxNextActions
import CmuxNextControl
import CmuxNextSettings
import CmuxNextPalette
import Foundation

/// Headless palette for agents and scripts: `palette.scopes {}` lists every
/// scope; `palette.query {scope, query?, limit?}` returns a scope's rows
/// ranked like the palette (`PaletteController.query`). Read-only; never
/// opens the palette or changes focus. `palette.run {scope, item, action?,
/// args?, focus?}` runs one of a row's typed actions through `action.run`
/// (palette-scopes.md 6.10), so the caller's origin, focus flag,
/// confirmation and idempotency rules apply unchanged.
enum PaletteScopeControl {
    nonisolated static let defaultLimit = 20
    nonisolated static let maximumLimit = 200

    static func methods(services: AppServices, router: ControlRouter) -> [ControlMethod] {
        [
            .mainActor("palette.scopes") { [weak services] _ in
                guard let palette = services?.palette else { return .value(.object(["scopes": .array([])])) }
                return .value(.object(["scopes": .array(palette.scopeDescriptors().map(json))]))
            },
            .async("palette.query") { [weak services] call in
                let (scope, query, limit) = try parameters(call.params)
                guard let rows = await rows(services: services, scope: scope, query: query, limit: limit) else {
                    throw ControlError.invalidParams(PaletteOpenRefusal.unknownScope(scope).message)
                }
                return .object(["scope": .string(scope), "query": .string(query), "complete": .bool(true), "items": .array(rows.map(json))])
            },
            .async("palette.run") { [weak services, weak router] call in
                let request = try runParameters(call.params)
                let ref = try await runnableRef(services: services, request)
                guard let router else { throw ControlError(code: "unavailable", message: PaletteOpenRefusal.unknownScope(request.scope).message) }
                switch await router.handle(ControlRequest(id: call.request.id, method: "action.run", params: actionRunParams(ref, call.params)),
                                           connection: call.connection) {
                case .success(let value): return value
                case .failure(let error): throw error
                }
            },
        ]
    }

    @MainActor
    private static func runnableRef(services: AppServices?, _ request: (scope: String, item: String, action: String?)) async throws -> PaletteActionRef {
        guard let palette = services?.palette else { throw scopeUnknown(request.scope) }
        do throws(PaletteRunSelection.Failure) {
            return try await palette.runnableRef(scope: PaletteScopeID(request.scope), item: request.item, action: request.action)
        } catch {
            switch error {
            case .unknownScope:
                throw scopeUnknown(request.scope)
            case .refused(let refusal):
                throw ControlError(code: refusal.code, message: refusal.message,
                                   data: ["scope": .string(request.scope), "item": .string(request.item)])
            }
        }
    }

    nonisolated static func scopeUnknown(_ scope: String) -> ControlError {
        ControlError(code: "palette.scope_unknown", message: PaletteOpenRefusal.unknownScope(scope).message, data: ["scope": .string(scope)])
    }

    nonisolated static func runParameters(_ params: [String: JSONValue]) throws -> (scope: String, item: String, action: String?) {
        guard let scope = params["scope"]?.stringValue, !scope.isEmpty else { throw ControlError.invalidParams("scope is required") }
        guard let item = params["item"]?.stringValue, !item.isEmpty else { throw ControlError.invalidParams("item is required") }
        if let value = params["action"], value.stringValue == nil, value != .null { throw ControlError.invalidParams("action must be a string") }
        switch params["args"] ?? params["arguments"] {
        case nil, .null, .object: break
        default: throw ControlError.invalidParams("args must be an object of name: value")
        }
        return (scope, item, params["action"]?.stringValue)
    }

    /// `action.run` params for `ref`: the caller's `args` over the ref's,
    /// and the caller's origin, focus, wait and idempotency key. A
    /// caller's `target` never replaces the row's.
    nonisolated static func actionRunParams(_ ref: PaletteActionRef, _ params: [String: JSONValue]) -> [String: JSONValue] {
        var arguments = ref.arguments.mapValues(json)
        if case .object(let given) = params["args"] ?? params["arguments"] {
            arguments.merge(given) { _, caller in caller }
        }
        var run: [String: JSONValue] = ["action": .string(ref.action.rawValue), "args": .object(arguments)]
        if let target = ref.target { run["target"] = .string(target.description) }
        for key in ["origin", "focus", "wait", "idempotency_key"] {
            if let value = params[key] { run[key] = value }
        }
        return run
    }

    nonisolated static func json(_ value: ActionValue) -> JSONValue {
        switch value {
        case .string(let text): .string(text)
        case .int(let number): JSONValue(number)
        case .bool(let flag): .bool(flag)
        case .target(let target): .string(target.description)
        }
    }

    nonisolated static func json(_ ref: PaletteActionRef) -> JSONValue {
        .object([
            "action": .string(ref.action.rawValue), "title": ref.title.map(JSONValue.string) ?? .null,
            "target": ref.target.map { .string($0.description) } ?? .null,
            "arguments": .object(ref.arguments.mapValues(json)), "destructive": .bool(ref.isDestructive),
        ])
    }

    @MainActor
    private static func rows(services: AppServices?, scope: String, query: String, limit: Int) async -> [PaletteQueryRow]? {
        guard let palette = services?.palette else { return nil }
        return await palette.query(scope: PaletteScopeID(scope), text: query, limit: limit)
    }

    nonisolated static func parameters(_ params: [String: JSONValue]) throws -> (scope: String, query: String, limit: Int) {
        guard let scope = params["scope"]?.stringValue, !scope.isEmpty else { throw ControlError.invalidParams("scope is required") }
        if let value = params["query"], value.stringValue == nil, value != .null { throw ControlError.invalidParams("query must be a string") }
        var limit = defaultLimit
        if let value = params["limit"] {
            guard let parsed = value.intValue, parsed > 0 else { throw ControlError.invalidParams("limit must be a positive integer") }
            limit = min(parsed, maximumLimit)
        }
        return (scope, params["query"]?.stringValue ?? "", limit)
    }

    nonisolated static func json(_ scope: PaletteScopeDescriptor) -> JSONValue {
        let parents: JSONValue
        switch scope.parents {
        case .root: parents = .string("root")
        case .anywhere: parents = .string("anywhere")
        case .only(let set): parents = .array(set.map(\.rawValue).sorted().map(JSONValue.string))
        }
        return .object([
            "id": .string(scope.id.rawValue), "title": .string(scope.title), "symbol": .string(scope.symbol),
            "prefix": scope.prefix.map(JSONValue.string) ?? .null, "keywords": .array(scope.keywords.map(JSONValue.string)),
            "parents": parents, "open_action": scope.openAction.map(JSONValue.string) ?? .null, "owner": .string(scope.owner),
        ])
    }

    nonisolated static func json(_ row: PaletteQueryRow) -> JSONValue {
        var object: [String: JSONValue] = [
            "id": .string(row.id), "title": .string(row.title), "score": .number(Double(row.score)), "enabled": .bool(row.isEnabled),
        ]
        let optional: [(String, String?)] = [
            ("subtitle", row.subtitle), ("accessory", row.accessory), ("section", row.section), ("symbol", row.symbol),
            ("action", row.actionID), ("enters", row.enters?.rawValue), ("drill", row.drills?.rawValue),
        ]
        for (key, value) in optional { if let value { object[key] = .string(value) } }
        object["actions"] = .array(row.actions.map(json))
        object["typed"] = .bool(!row.actions.isEmpty)
        return .object(object)
    }
}
