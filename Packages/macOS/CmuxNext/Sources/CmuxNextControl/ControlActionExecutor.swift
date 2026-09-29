public import CmuxNextSettings

/// A reference to one object (`--target tab-group:g1`), in wire form.
public struct ControlTargetRef: Sendable, Hashable, CustomStringConvertible {
    /// Target kind as its CLI prefix (`workspace-group`).
    public var kind: String
    public var id: String

    public init(kind: String, id: String) {
        self.kind = kind
        self.id = id
    }

    public var description: String { "\(kind):\(id)" }

    var json: JSONValue { .object(["kind": .string(kind), "id": .string(id)]) }
}

/// A validated argument value.
public enum ControlValue: Sendable, Hashable {
    case string(String)
    case int(Int)
    case bool(Bool)
    case target(ControlTargetRef)

    var json: JSONValue {
        switch self {
        case .string(let value): .string(value)
        case .int(let value): JSONValue(value)
        case .bool(let value): .bool(value)
        case .target(let ref): .string(ref.description)
        }
    }
}

/// A validated `action.run` request: the canonical action ID, the target,
/// and arguments already checked against the action's schema.
public struct ControlActionRequest: Sendable, Hashable {
    public var actionID: String
    public var target: ControlTargetRef?
    public var arguments: [String: ControlValue]

    public init(actionID: String, target: ControlTargetRef? = nil, arguments: [String: ControlValue] = [:]) {
        self.actionID = actionID
        self.target = target
        self.arguments = arguments
    }
}

/// What happened when the executor tried to run an action.
public enum ControlActionOutcome: Sendable, Hashable {
    case ran
    case unknownAction
    /// The catalog has the action but the App bound no handler.
    case notBound
    /// Its required context is missing (for example a browser action with
    /// no browser focused).
    case unavailable
    /// Its handler's `isEnabled` predicate refused.
    case disabled
}

/// Runs actions for `action.run`. The App's implementation
/// (`RegistryControlBridge`) hops to the main actor and calls
/// `ActionRegistry.perform`; tests inject a fake.
public protocol ControlActionExecutor: Sendable {
    func runAction(_ request: ControlActionRequest) async -> ControlActionOutcome
}

/// `settings.get` / `settings.set` storage. `CmuxConfigFile` conforms, so
/// writes land in cmux.json and the settings watcher applies them.
public protocol ControlSettingsStore: Sendable {
    func value(at path: [String]) async throws -> JSONValue?
    func set(_ value: JSONValue, at path: [String]) async throws
    func remove(_ path: [String]) async throws
    var fileLocation: String { get }
}

extension CmuxConfigFile: ControlSettingsStore {
    public nonisolated var fileLocation: String { url.path }
}

/// Facts `system.identify` reports about the running app.
public struct ControlIdentity: Sendable {
    public var appName: String
    public var version: String
    public var build: String
    public var bundleID: String?
    public var tag: String?
    public var processID: Int32

    public init(appName: String = "cmux-next", version: String, build: String, bundleID: String?, tag: String?, processID: Int32) {
        self.appName = appName
        self.version = version
        self.build = build
        self.bundleID = bundleID
        self.tag = tag
        self.processID = processID
    }
}
