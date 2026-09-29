public import CmuxNextSettings
import Foundation

/// Schema validation for `action.run`, done on the connection's task so only
/// the validated request reaches the main actor.
extension ControlRouter {
    static func resolveAction(_ params: [String: JSONValue], in catalog: ControlCatalog) throws -> ControlActionInfo {
        guard let name = (params["action"] ?? params["id"] ?? params["cli_name"])?.stringValue, !name.isEmpty else {
            throw ControlError.invalidParams("params.action is required (an action id or CLI name)")
        }
        guard let action = catalog.resolve(name) else {
            throw ControlError(code: "not_found", message: "Unknown action '\(name)'", data: ["action": .string(name)])
        }
        return action
    }

    /// Checks target and arguments against the schema.
    static func validatedRequest(for action: ControlActionInfo, params: [String: JSONValue], knownKinds: [String]) throws -> ControlActionRequest {
        var request = ControlActionRequest(actionID: action.id)
        if let rawTarget = params["target"], !rawTarget.isNull {
            request.target = try target(from: rawTarget, allowedKinds: action.targets, knownKinds: knownKinds, action: action.id)
        }
        let rawArguments: [String: JSONValue]
        switch params["args"] ?? params["arguments"] {
        case .object(let members): rawArguments = members
        case nil, .null: rawArguments = [:]
        default: throw ControlError.invalidParams("args must be an object of name: value")
        }
        let schema = Dictionary(action.arguments.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        for (name, raw) in rawArguments {
            guard let argument = schema[name] else {
                throw ControlError.invalidParams(
                    "\(action.id) has no argument '\(name)'",
                    data: ["valid": .array(action.arguments.map { .string($0.name) })]
                )
            }
            request.arguments[name] = try value(raw, for: argument, action: action.id, knownKinds: knownKinds)
        }
        let interactive = params["interactive"]?.boolValue ?? false
        let missing = action.arguments.filter { $0.isRequired && request.arguments[$0.name] == nil }.map(\.name)
        if !missing.isEmpty, !interactive {
            throw ControlError.invalidParams(
                "\(action.id) requires \(missing.map { "--\($0)" }.joined(separator: ", "))",
                data: ["missing": .array(missing.map(JSONValue.string))]
            )
        }
        return request
    }

    static func value(_ raw: JSONValue, for argument: ControlArgumentInfo, action: String, knownKinds: [String]) throws -> ControlValue {
        func fail(_ expected: String) -> ControlError {
            .invalidParams("\(action) argument '\(argument.name)' expects \(expected)", data: ["argument": .string(argument.name)])
        }
        switch argument.kind {
        case .string:
            switch raw {
            case .string(let text): return .string(text)
            case .number, .bool: return .string(raw.compactText)
            default: throw fail("a string")
            }
        case .int:
            let number = raw.intValue ?? raw.stringValue.flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            guard let number else { throw fail("an integer") }
            if let range = argument.range, !range.contains(number) { throw fail("an integer in \(range.lowerBound)...\(range.upperBound)") }
            return .int(number)
        case .bool:
            if let flag = raw.boolValue { return .bool(flag) }
            switch raw.stringValue?.lowercased() ?? raw.intValue.map(String.init) {
            case "true", "yes", "on", "1": return .bool(true)
            case "false", "no", "off", "0": return .bool(false)
            default: throw fail("true or false")
            }
        case .enumeration:
            guard let text = raw.stringValue?.trimmingCharacters(in: .whitespaces),
                  let choice = argument.choices.first(where: { $0.value.lowercased() == text.lowercased() }) else {
                throw fail("one of \(argument.choices.map(\.value).joined(separator: ", "))")
            }
            return .string(choice.value)
        case .target:
            let kind = argument.targetKind.map { [$0] } ?? []
            return .target(try target(from: raw, allowedKinds: kind, knownKinds: knownKinds, action: action))
        }
    }

    /// Parses `kind:id`, `{kind, id}`, or a bare id (the first allowed kind).
    /// Kinds match after dropping case, `-`, and `_`, so `workspaceGroup`,
    /// `workspace_group`, and `workspace-group` name the same kind.
    static func target(from raw: JSONValue, allowedKinds: [String], knownKinds: [String], action: String) throws -> ControlTargetRef {
        let kindText: String?
        let id: String
        switch raw {
        case .string(let text):
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            let colon = trimmed.firstIndex(of: ":")
            let prefix = colon.map { String(trimmed[..<$0]) } ?? ""
            if let colon, knownKinds.contains(where: { normalizedKind($0) == normalizedKind(prefix) })
                || allowedKinds.contains(where: { normalizedKind($0) == normalizedKind(prefix) }) {
                kindText = prefix
                id = String(trimmed[trimmed.index(after: colon)...])
            } else {
                kindText = nil
                id = trimmed
            }
        case .object(let members):
            kindText = members["kind"]?.stringValue
            id = members["id"]?.stringValue ?? ""
        default:
            throw ControlError.invalidParams("target must be kind:id")
        }
        guard !id.isEmpty else { throw ControlError.invalidParams("target id is empty") }
        guard !allowedKinds.isEmpty else {
            throw ControlError.invalidParams("\(action) does not take a target")
        }
        guard let kindText else { return ControlTargetRef(kind: allowedKinds[0], id: id) }
        guard let kind = allowedKinds.first(where: { normalizedKind($0) == normalizedKind(kindText) }) else {
            throw ControlError.invalidParams(
                "\(action) takes a target of kind \(allowedKinds.joined(separator: " or ")), not \(kindText)",
                data: ["targets": .array(allowedKinds.map(JSONValue.string))]
            )
        }
        return ControlTargetRef(kind: kind, id: id)
    }

    static func normalizedKind(_ kind: String) -> String {
        kind.lowercased().filter { $0 != "-" && $0 != "_" }
    }
}
