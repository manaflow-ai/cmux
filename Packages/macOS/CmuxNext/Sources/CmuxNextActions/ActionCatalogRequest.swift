import Foundation

/// The one daemon request an action's catalog row names (cmux-action-catalog `Action::request`):
/// the app sends it with no handler of its own (`CatalogRequestHandlers`). The operation is
/// compiled catalog data, never user config; cmux-tui's `catalog_request_matches_cli` checks
/// that it is what the row's CLI verb sends.
public nonisolated struct ActionCatalogRequest: Sendable, Hashable {
    /// Where the request goes. There is no CLI lane: the app never runs the `cmux` CLI or
    /// another child process to do a product task.
    public enum Lane: String, Sendable, Hashable {
        /// A `cmux.protocol/2` resource operation on the session host.
        case session
        /// A method of the app's own control router.
        case app
        /// A method of the acpmux daemon.
        case acpmux
    }

    /// A param's fixed value.
    public enum Constant: Sendable, Hashable {
        case string(String)
        case int(Int)
        case bool(Bool)
    }

    /// Where one param takes its value from.
    public enum Source: Sendable, Hashable {
        /// The action's argument of this name; left out when omitted.
        case argument(String)
        /// The daemon id of the invocation's target of this kind, else the focused one.
        case target(ActionTargetKind)
        case constant(Constant)
    }

    public struct Param: Sendable, Hashable {
        public let name: String
        public let source: Source
    }

    public let lane: Lane
    public let operation: String
    public let params: [Param]

    public init(lane: Lane, operation: String, params: [Param]) {
        self.lane = lane
        self.operation = operation
        self.params = params
    }

    /// The export's `request` member (`{lane, operation, params: [{name, argument|target|constant}]}`),
    /// nil when it does not decode: a row that does not decode gets no binding, so the conformance
    /// test names it as unbound.
    static func decode(_ wire: Any?) -> ActionCatalogRequest? {
        guard let wire = wire as? [String: Any], let lane = (wire["lane"] as? String).flatMap(Lane.init(rawValue:)),
              let operation = wire["operation"] as? String, !operation.isEmpty
        else { return nil }
        var params: [Param] = []
        for row in wire["params"] as? [[String: Any]] ?? [] {
            guard let name = row["name"] as? String else { return nil }
            if let argument = row["argument"] as? String {
                params.append(Param(name: name, source: .argument(argument)))
            } else if let kind = (row["target"] as? String).flatMap(ActionTargetKind.init(rawValue:)) {
                params.append(Param(name: name, source: .target(kind)))
            } else if let constant = constant(row["constant"]) {
                params.append(Param(name: name, source: .constant(constant)))
            } else {
                return nil
            }
        }
        return ActionCatalogRequest(lane: lane, operation: operation, params: params)
    }

    private static func constant(_ value: Any?) -> Constant? {
        // JSONSerialization gives a JSON bool as an NSNumber that also casts to Int: test it first.
        #if canImport(Darwin)
        if let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() { return .bool(number.boolValue) }
        #else
        // Linux's Foundation has no CFBoolean: its JSON bools are the NSNumbers of objCType "c".
        if let number = value as? NSNumber, String(cString: number.objCType) == "c" { return .bool(number.boolValue) }
        #endif
        if let int = value as? Int { return .int(int) }
        if let text = value as? String { return .string(text) }
        return nil
    }
}

/// An `op:<operation>` suggestion source: one list request whose rows give the values
/// (`value`) and titles (`title`); `items` names the result member that holds the rows, nil
/// when the result is the array.
public nonisolated struct ActionCatalogListSource: Sendable, Hashable {
    public let lane: ActionCatalogRequest.Lane
    public let operation: String
    public let items: String?
    public let value: String
    public let title: String

    public init(lane: ActionCatalogRequest.Lane, operation: String, items: String?, value: String, title: String) {
        self.lane = lane
        self.operation = operation
        self.items = items
        self.value = value
        self.title = title
    }

    /// The suggestion source prefix these sources carry.
    public static let prefix = "op:"

    static func decode(_ wire: Any?) -> ActionCatalogListSource? {
        guard let wire = wire as? [String: Any], let lane = (wire["lane"] as? String).flatMap(ActionCatalogRequest.Lane.init(rawValue:)),
              let operation = wire["operation"] as? String, let value = wire["value"] as? String, let title = wire["title"] as? String
        else { return nil }
        return ActionCatalogListSource(lane: lane, operation: operation, items: wire["items"] as? String, value: value, title: title)
    }
}

extension ActionCatalogRequest {
    /// One param's value as it goes on the wire.
    public enum Value: Sendable, Hashable {
        case string(String)
        case int(Int)
        case bool(Bool)
        /// A several-valued argument (``ActionSuggestions/allowsMultiple``, comma-joined in the
        /// invocation): a list, as the CLI sends one.
        case strings([String])
    }

    /// The params this request sends for `invocation` (as cmux-action-catalog's
    /// `request::params`): each argument's value (an omitted or empty one is left out), each
    /// target's daemon id from `target`, each constant. Fails with the target kind when
    /// `target` has none of it.
    ///
    /// - Parameters:
    ///   - arguments: The action's declared arguments (whether one takes several values).
    ///   - invocation: The run.
    ///   - target: The daemon id of the invocation's target of a kind, else of the focused one.
    public func values(arguments: [ActionArgument], invocation: ActionInvocation,
                       target: (ActionTargetKind) -> String?) -> Result<[String: Value], MissingTarget> {
        var values: [String: Value] = [:]
        for param in params {
            switch param.source {
            case .constant(.string(let text)): values[param.name] = .string(text)
            case .constant(.int(let number)): values[param.name] = .int(number)
            case .constant(.bool(let flag)): values[param.name] = .bool(flag)
            case .target(let kind):
                guard let id = target(kind) else { return .failure(MissingTarget(kind: kind)) }
                values[param.name] = .string(id)
            case .argument(let name):
                let multiple = arguments.first { $0.name == name }?.suggestions?.allowsMultiple ?? false
                switch invocation[name] {
                case .string(let text)? where multiple:
                    let items = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                    if !items.isEmpty { values[param.name] = .strings(items) }
                case .string(let text)? where !text.isEmpty: values[param.name] = .string(text)
                case .int(let number)?: values[param.name] = .int(number)
                case .bool(let flag)?: values[param.name] = .bool(flag)
                case .target(let ref)?: values[param.name] = .string(ref.id)
                default: break
                }
            }
        }
        return .success(values)
    }

    /// A target param with no target of its kind to read.
    public struct MissingTarget: Error, Sendable, Hashable {
        public let kind: ActionTargetKind
    }
}
