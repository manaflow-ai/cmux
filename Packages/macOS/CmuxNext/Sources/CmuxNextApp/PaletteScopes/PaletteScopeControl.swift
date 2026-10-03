import CmuxNextControl
import CmuxNextSettings
import CmuxNextPalette
import Foundation

/// Headless palette for agents and scripts: `palette.scopes {}` lists every
/// scope; `palette.query {scope, query?, limit?}` returns a scope's rows
/// ranked like the palette (`PaletteController.query`). Read-only; never
/// opens the palette or changes focus.
enum PaletteScopeControl {
    nonisolated static let defaultLimit = 20
    nonisolated static let maximumLimit = 200

    static func methods(services: AppServices) -> [ControlMethod] {
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
        ]
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
        return .object(object)
    }
}
