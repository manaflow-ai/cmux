public import CmuxNextSettings
import Foundation

/// Schema validation for `action.run`, done on the connection's task so only
/// the validated request reaches the main actor.
extension ControlRouter {
    static func resolveAction(_ params: [String: JSONValue], in catalog: ControlCatalog) throws -> ControlActionInfo {
        guard let name = (params["action"] ?? params["id"] ?? params["cli_name"])?.stringValue, !name.isEmpty else {
            throw ControlError.invalidParams(ControlStrings.text("control.error.actionParamRequired", "params.action is required (an action id or CLI name)"))
        }
        // A CLI verb (`cli: true`) names only actions marked for the CLI,
        // by CLI name, so a GUI-only action is never reachable that way.
        if params["cli"]?.boolValue == true {
            guard let action = catalog.resolveCLIName(name), action.isCLI else {
                throw ControlError(code: "not_found", message: ControlStrings.format("control.error.unknownCLIAction", "No CLI command '%@'", name),
                                   data: ["action": .string(name), "cli": true])
            }
            try refuseDisabledFeature(action, name)
            return action
        }
        guard let action = catalog.resolve(name) else {
            throw ControlError(code: "not_found", message: ControlStrings.format("control.error.unknownAction", "Unknown action '%@'", name), data: ["action": .string(name)])
        }
        try refuseDisabledFeature(action, name)
        return action
    }

    /// `feature.disabled` for an action whose feature an administrator turned off.
    static func refuseDisabledFeature(_ action: ControlActionInfo, _ name: String) throws {
        guard let feature = action.disabledFeature else { return }
        try check(.featureDisabled(feature), action: name)
    }

    /// Checks target and arguments against the schema.
    /// `connection` decides whether the caller may name the user
    /// (``ControlOrigin``): a socket caller never may.
    static func validatedRequest(for action: ControlActionInfo, params: [String: JSONValue], knownKinds: [String],
                                 connection: ControlConnectionID) throws -> ControlActionRequest {
        var request = ControlActionRequest(actionID: action.id)
        if let origin = try ControlOrigin().validated(params["origin"], connection: connection) {
            request.origin = origin
        }
        if let focus = params["focus"], !focus.isNull {
            guard let value = focus.boolValue else {
                throw ControlError.invalidParams(ControlStrings.text("control.error.focusShape", "focus must be true or false"))
            }
            request.focus = value
        }
        if let rawTarget = params["target"], !rawTarget.isNull {
            request.target = try target(from: rawTarget, allowedKinds: action.targets, knownKinds: knownKinds, action: action.id)
        }
        let rawArguments: [String: JSONValue]
        switch params["args"] ?? params["arguments"] {
        case .object(let members): rawArguments = members
        case nil, .null: rawArguments = [:]
        default: throw ControlError.invalidParams(ControlStrings.text("control.error.argsShape", "args must be an object of name: value"))
        }
        let schema = Dictionary(action.arguments.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        for (given, raw) in rawArguments {
            // Rooms became Spaces: `--room` still names the `space` argument.
            let name = schema[given] == nil ? Self.renamedArguments[given].flatMap { schema[$0] == nil ? nil : $0 } ?? given : given
            guard let argument = schema[name] else {
                throw ControlError.invalidParams(
                    ControlStrings.format("control.error.noSuchArgument", "%1$@ has no argument '%2$@'", action.id, name),
                    data: ["valid": .array(action.arguments.map { .string($0.name) })]
                )
            }
            request.arguments[name] = try value(raw, for: argument, action: action.id, knownKinds: knownKinds)
        }
        let interactive = params["interactive"]?.boolValue ?? false
        let missing = action.arguments.filter { $0.isRequired && request.arguments[$0.name] == nil }.map(\.name)
        if !missing.isEmpty, !interactive {
            throw ControlError.invalidParams(
                ControlStrings.format("control.error.missingArguments", "%1$@ requires %2$@", action.id, missing.map { "--\($0)" }.joined(separator: ", ")),
                data: ["missing": .array(missing.map(JSONValue.string))]
            )
        }
        return request
    }

    /// Old argument names and the ones that replaced them (data-model.md 3.4).
    static let renamedArguments = ["room": "space"]

    static func value(_ raw: JSONValue, for argument: ControlArgumentInfo, action: String, knownKinds: [String]) throws -> ControlValue {
        func fail(_ expected: String) -> ControlError {
            .invalidParams(ControlStrings.format("control.error.argumentExpects", "%1$@ argument '%2$@' expects %3$@", action, argument.name, expected), data: ["argument": .string(argument.name)])
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
            throw ControlError.invalidParams(ControlStrings.text("control.error.targetShape", "target must be kind:id"))
        }
        guard !id.isEmpty else { throw ControlError.invalidParams(ControlStrings.text("control.error.targetIDEmpty", "target id is empty")) }
        guard !allowedKinds.isEmpty else {
            throw ControlError.invalidParams(ControlStrings.format("control.error.noTarget", "%@ does not take a target", action))
        }
        guard let kindText else { return ControlTargetRef(kind: allowedKinds[0], id: id) }
        guard let kind = allowedKinds.first(where: { normalizedKind($0) == normalizedKind(kindText) }) else {
            throw ControlError.invalidParams(
                ControlStrings.format("control.error.wrongTargetKind", "%1$@ takes a target of kind %2$@, not %3$@", action, allowedKinds.joined(separator: "|"), kindText),
                data: ["targets": .array(allowedKinds.map(JSONValue.string))]
            )
        }
        return ControlTargetRef(kind: kind, id: id)
    }

    static func normalizedKind(_ kind: String) -> String {
        kind.lowercased().filter { $0 != "-" && $0 != "_" }
    }
}
