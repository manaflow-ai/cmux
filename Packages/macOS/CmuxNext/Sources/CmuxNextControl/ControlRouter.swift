public import CmuxNextSettings
import Foundation
import Synchronization

/// A decoded v2 request line: `{"id": …, "method": "…", "params": {…}}`,
/// the framing the old app's control socket and the `cmux` CLI use.
public struct ControlRequest: Sendable {
    public var id: JSONValue?
    public var method: String
    public var params: [String: JSONValue]

    public init(id: JSONValue? = nil, method: String, params: [String: JSONValue] = [:]) {
        self.id = id
        self.method = method
        self.params = params
    }
}

/// A protocol-level failure, encoded as `{"ok": false, "error": {…}}`.
public struct ControlError: Error, Sendable, Hashable {
    public var code: String
    public var message: String
    public var data: JSONValue?

    public init(code: String, message: String, data: JSONValue? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }

    static func invalidParams(_ message: String, data: JSONValue? = nil) -> ControlError {
        ControlError(code: "invalid_params", message: message, data: data)
    }
}

/// Answers control-socket methods. Transport and authorization live in
/// `ControlSocketServer`; this type is pure request -> response, so tests
/// can drive it without a socket.
///
/// Only `action.run` reaches the main actor (through the executor).
/// `action.list` and `action.describe` read the catalog snapshot the App
/// bridge publishes; `settings.*` go to the settings store actor.
public final class ControlRouter: Sendable {
    /// Methods this router answers, reported by `system.capabilities`.
    public static let methods = [
        "system.ping", "system.identify", "system.capabilities",
        "action.list", "action.describe", "action.run",
        "settings.get", "settings.set", "settings.unset",
    ]

    /// Wire protocol version reported by `system.ping` and `system.identify`.
    public static let protocolVersion = 1

    public let identity: ControlIdentity
    private let executor: any ControlActionExecutor
    private let settings: (any ControlSettingsStore)?
    private let state: Mutex<State>

    struct State {
        var catalog: ControlCatalog = .empty
        var socketPath: String?
        var accessMode: String?
    }

    public init(identity: ControlIdentity, executor: any ControlActionExecutor, settings: (any ControlSettingsStore)? = nil) {
        self.identity = identity
        self.executor = executor
        self.settings = settings
        self.state = Mutex(State())
    }

    // MARK: - Catalog

    public var catalog: ControlCatalog { state.withLock { $0.catalog } }

    public func updateCatalog(_ catalog: ControlCatalog) {
        state.withLock { $0.catalog = catalog }
    }

    public func updateContextMask(_ mask: UInt32) {
        state.withLock { $0.catalog.contextMask = mask }
    }

    func setTransportInfo(socketPath: String, accessMode: String) {
        state.withLock {
            $0.socketPath = socketPath
            $0.accessMode = accessMode
        }
    }

    // MARK: - Lines

    /// Decodes one line and returns the response line (without newline).
    public func response(forLine line: String) async -> String {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{") else {
            // v1 plain-text commands: only the liveness probe is kept.
            switch trimmed.split(separator: " ", maxSplits: 1).first.map({ $0.lowercased() }) {
            case "ping": return "PONG"
            default: return "ERROR: Unknown command '\(trimmed.split(separator: " ").first ?? "")'. cmux-next speaks v2 JSON requests only."
            }
        }
        let request: ControlRequest
        switch Self.decode(trimmed) {
        case .success(let decoded): request = decoded
        case .failure(let error): return Self.encode(id: nil, error: error)
        }
        return Self.encode(id: request.id, result: await handle(request))
    }

    static func decode(_ line: String) -> Result<ControlRequest, ControlError> {
        guard let value = try? JSONValue.parse(Data(line.utf8)) else {
            return .failure(ControlError(code: "parse_error", message: "Invalid JSON"))
        }
        guard case .object(let members) = value else {
            return .failure(ControlError(code: "invalid_request", message: "Expected JSON object"))
        }
        let method = members["method"]?.stringValue?.trimmingCharacters(in: .whitespaces) ?? ""
        guard !method.isEmpty else {
            return .failure(ControlError(code: "invalid_request", message: "Missing method"))
        }
        return .success(ControlRequest(id: members["id"], method: method, params: members["params"]?.objectValue ?? [:]))
    }

    static func encode(id: JSONValue?, result: Result<JSONValue, ControlError>) -> String {
        switch result {
        case .success(let value):
            return JSONValue.object(["id": id ?? .null, "ok": .bool(true), "result": value]).compactText
        case .failure(let error):
            return encode(id: id, error: error)
        }
    }

    static func encode(id: JSONValue?, error: ControlError) -> String {
        var body: [String: JSONValue] = ["code": .string(error.code), "message": .string(error.message)]
        if let data = error.data { body["data"] = data }
        return JSONValue.object(["id": id ?? .null, "ok": .bool(false), "error": .object(body)]).compactText
    }

    // MARK: - Dispatch

    public func handle(_ request: ControlRequest) async -> Result<JSONValue, ControlError> {
        do {
            return .success(try await dispatch(request))
        } catch let error as ControlError {
            return .failure(error)
        } catch {
            return .failure(ControlError(code: "internal_error", message: String(describing: error)))
        }
    }

    private func dispatch(_ request: ControlRequest) async throws -> JSONValue {
        let params = request.params
        switch request.method {
        case "system.ping":
            return ["pong": true, "app": .string(identity.appName), "protocol_version": JSONValue(Self.protocolVersion)]
        case "system.identify":
            return identify()
        case "system.capabilities":
            return ["protocol_version": JSONValue(Self.protocolVersion), "methods": .array(Self.methods.map(JSONValue.string))]
        case "action.list":
            return list(params)
        case "action.describe":
            let catalog = self.catalog
            let action = try resolveAction(params, in: catalog)
            return ["action": catalog.json(action)]
        case "action.run":
            return try await run(params)
        case "settings.get":
            let store = try settingsStore()
            let path = try Self.settingsPath(params, allowEmpty: true)
            let value = try await store.value(at: path)
            return ["path": .array(path.map(JSONValue.string)), "exists": .bool(value != nil), "value": value ?? .null, "file": .string(store.fileLocation)]
        case "settings.set":
            let store = try settingsStore()
            let path = try Self.settingsPath(params, allowEmpty: false)
            guard let value = params["value"] else { throw ControlError.invalidParams("settings.set requires params.value") }
            try await store.set(value, at: path)
            return ["path": .array(path.map(JSONValue.string)), "value": value, "file": .string(store.fileLocation)]
        case "settings.unset":
            let store = try settingsStore()
            let path = try Self.settingsPath(params, allowEmpty: false)
            try await store.remove(path)
            return ["path": .array(path.map(JSONValue.string)), "file": .string(store.fileLocation)]
        default:
            throw ControlError(code: "method_not_found", message: "Unknown method \(request.method)", data: ["method": .string(request.method)])
        }
    }

    private func identify() -> JSONValue {
        let transport = state.withLock { ($0.socketPath, $0.accessMode) }
        return [
            "app": .string(identity.appName),
            "version": .string(identity.version),
            "build": .string(identity.build),
            "bundle_id": identity.bundleID.map(JSONValue.string) ?? .null,
            "tag": identity.tag.map(JSONValue.string) ?? .null,
            "pid": JSONValue(Int(identity.processID)),
            "socket_path": transport.0.map(JSONValue.string) ?? .null,
            "access_mode": transport.1.map(JSONValue.string) ?? .null,
            "protocol_version": JSONValue(Self.protocolVersion),
            "methods": .array(Self.methods.map(JSONValue.string)),
        ]
    }

    private func list(_ params: [String: JSONValue]) -> JSONValue {
        let catalog = self.catalog
        let category = params["category"]?.stringValue?.lowercased()
        let noun = params["noun"]?.stringValue?.lowercased()
        let availableOnly = params["available_only"]?.boolValue ?? false
        let actions = catalog.actions.filter { action in
            if let category, action.category.lowercased() != category { return false }
            if let noun, action.cliName.split(separator: " ").first.map(String.init) != noun { return false }
            if availableOnly, !catalog.isAvailable(action) { return false }
            return true
        }
        var categories: [String] = []
        for action in catalog.actions where !categories.contains(action.category) { categories.append(action.category) }
        return [
            "actions": .array(actions.map(catalog.json)),
            "categories": .array(categories.map(JSONValue.string)),
            "count": JSONValue(actions.count),
        ]
    }

    private func settingsStore() throws -> any ControlSettingsStore {
        guard let settings else { throw ControlError(code: "unavailable", message: "settings are not available") }
        return settings
    }

    static func settingsPath(_ params: [String: JSONValue], allowEmpty: Bool) throws -> [String] {
        let path: [String]
        switch params["path"] ?? params["key"] {
        case .string(let dotted): path = CmuxConfigFile.keyPath(from: dotted)
        case .array(let items):
            let keys = items.compactMap(\.stringValue)
            guard keys.count == items.count else { throw ControlError.invalidParams("path array must contain strings") }
            path = keys
        case nil, .null: path = []
        default: throw ControlError.invalidParams("path must be a dotted string or an array of keys")
        }
        guard allowEmpty || !path.isEmpty else { throw ControlError.invalidParams("path is required") }
        guard !path.contains(where: \.isEmpty) else { throw ControlError.invalidParams("path has an empty key") }
        return path
    }

    // MARK: - action.run

    private func resolveAction(_ params: [String: JSONValue], in catalog: ControlCatalog) throws -> ControlActionInfo {
        guard let name = (params["action"] ?? params["id"] ?? params["cli_name"])?.stringValue, !name.isEmpty else {
            throw ControlError.invalidParams("params.action is required (an action id or CLI name)")
        }
        guard let action = catalog.resolve(name) else {
            throw ControlError(code: "not_found", message: "Unknown action '\(name)'", data: ["action": .string(name)])
        }
        return action
    }

    private func run(_ params: [String: JSONValue]) async throws -> JSONValue {
        let catalog = self.catalog
        let action = try resolveAction(params, in: catalog)
        let request = try Self.validatedRequest(for: action, params: params, knownKinds: catalog.targetKinds)
        guard catalog.isAvailable(action) || action.unavailableReason != nil else {
            throw ControlError(code: "unavailable", message: "\(action.id) is not available in the current context", data: [
                "action": .string(action.id), "requires": .array(action.requires.map(JSONValue.string)),
            ])
        }
        switch await executor.runAction(request) {
        case .ran:
            var result: [String: JSONValue] = [
                "action": .string(action.id),
                "ran": true,
                "args": .object(request.arguments.mapValues(\.json)),
            ]
            if let target = request.target { result["target"] = target.json }
            return .object(result)
        case .unknownAction:
            throw ControlError(code: "not_found", message: "Unknown action '\(action.id)'")
        case .notBound:
            throw ControlError(code: "not_bound", message: "\(action.id) has no handler in this build", data: ["action": .string(action.id)])
        case .unavailable:
            throw ControlError(code: "unavailable", message: "\(action.id) is not available in the current context", data: ["action": .string(action.id)])
        case .disabled:
            throw ControlError(code: "disabled", message: "\(action.id) is disabled right now", data: ["action": .string(action.id)])
        case .refused(let reason):
            throw ControlError(code: "unavailable", message: "\(action.id) unavailable: \(reason)", data: ["action": .string(action.id), "reason": .string(reason)])
        }
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
