public import CmuxNextActions
import CmuxNextCloud
public import Foundation

/// The Cloud handlers' rules, asked of Rust (cmux-tui/crates/cmux-cloud-handlers, with their tests)
/// over the app FFI's JSON channel (ops `cloud_handler_*`, ``CloudStartCore``). The handlers read
/// the facts (arguments, machine models, API answers), ask here, and do the platform work; a
/// refusal comes back as a key the app puts in its localized words (`words`).
public nonisolated struct CloudHandlerRules: Sendable {
    /// What the rules said: a key into the app's strings and the values it names. `unavailable`:
    /// the rules did not answer (the app's FFI is missing an op).
    public struct Said: Equatable, Sendable {
        public var key: String
        public var args: [String] = []
        public var kind: String?

        public init(key: String, args: [String] = [], kind: String? = nil) {
            self.key = key
            self.args = args
            self.kind = kind
        }
    }

    /// The app's refusal for what the rules said, in its own (main-actor) words.
    public typealias Words = @MainActor @Sendable (Said) -> ActionFailure

    private let core = CloudStartCore()
    private let words: Words

    public init(words: @escaping Words) {
        self.words = words
    }

    /// One op's answer as JSON; nil when the FFI does not answer.
    public func ask(_ operation: String, _ request: [String: Any]) -> [String: Any]? {
        guard JSONSerialization.isValidJSONObject(request),
              let data = try? JSONSerialization.data(withJSONObject: request),
              let reply = core.callData(operation, data, startingCapacity: 16_384) else { return nil }
        return (try? JSONSerialization.jsonObject(with: reply)) as? [String: Any]
    }

    /// The invocation's arguments as the rules read them (a target is not an argument they check).
    public static func json(_ arguments: [String: ActionValue]) -> [String: Any] {
        arguments.compactMapValues { value -> Any? in
            switch value {
            case .string(let text): text
            case .int(let number): number
            case .bool(let flag): flag
            case .target: nil
            }
        }
    }

    /// An answer that may be a refusal (`{"refusal"}`): the answer, else the refusal thrown.
    @MainActor
    public func answered(_ operation: String, _ request: [String: Any]) throws -> [String: Any] {
        guard let reply = ask(operation, request) else { throw words(Said(key: "unavailable")) }
        if let refusal = reply["refusal"], !(refusal is NSNull) { throw words(Self.decodeSaid(refusal)) }
        return reply
    }

    /// A `{"value"}` / `{"refusal"}` answer: the value, else the refusal thrown.
    @MainActor
    public func checked(_ operation: String, _ request: [String: Any], valueKey: String = "value") throws -> Any {
        try answered(operation, request)[valueKey] ?? NSNull()
    }

    /// One argument check (`check`) of `invocation`; `names`: the machine and port its refusal
    /// names (`name`, `id`, `port`).
    @MainActor
    public func arg(_ check: String, _ invocation: ActionInvocation, names: [String: Any]?, extra: [String: Any]) throws -> Any {
        var request = extra
        request["check"] = check
        request["args"] = Self.json(invocation.arguments)
        if let names { request["names"] = names }
        return try checked("cloud_handler_arg", request)
    }

    /// `fields`-shaped answers (`{"fields": {...}}`).
    public func fields(_ operation: String, _ request: [String: Any]) -> [String: ActionResultValue] {
        guard case .object(let fields)? = (ask(operation, request)?["fields"]).map(Self.result) else { return [:] }
        return fields
    }

    public func machineFields(_ machineID: String, _ extra: [String: ActionResultValue] = [:]) -> [String: ActionResultValue] {
        fields("cloud_handler_machine_fields", ["machineId": machineID, "extra": Self.json(.object(extra))])
    }

    /// A read answer: its text (nil: the app's own "nothing here"), whether it copies, and its fields.
    public struct Answer {
        public var text: String?
        public var copyable = true
        public var fields: [String: ActionResultValue] = [:]
    }

    public func answer(_ request: [String: Any]) -> Answer {
        Self.answer(ask("cloud_handler_answer", request))
    }

    public static func answer(_ reply: [String: Any]?) -> Answer {
        guard let reply else { return Answer(text: nil) }
        var fields: [String: ActionResultValue] = [:]
        if case .object(let object)? = reply["fields"].map(result) { fields = object }
        return Answer(text: reply["text"] as? String, copyable: reply["copyable"] as? Bool ?? true, fields: fields)
    }

    /// An encodable value (a daemon's JSON) as the rules' JSON.
    public static func any(_ value: some Encodable) -> Any {
        (try? JSONEncoder().encode(value)).flatMap { try? JSONSerialization.jsonObject(with: $0, options: .fragmentsAllowed) } ?? NSNull()
    }

    /// A JSON value as an ``ActionResultValue``: a number written with a fraction stays a double.
    public static func result(_ value: Any) -> ActionResultValue {
        switch value {
        case let text as String: return .string(text)
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return .bool(number.boolValue) }
            return CFNumberIsFloatType(number) ? .double(number.doubleValue) : .int(number.intValue)
        case let list as [Any]: return .array(list.map(result))
        case let object as [String: Any]: return .object(object.mapValues(result))
        default: return .null
        }
    }

    public static func json(_ value: ActionResultValue) -> Any {
        switch value {
        case .string(let text): text
        case .int(let number): number
        case .double(let number): number
        case .bool(let flag): flag
        case .null: NSNull()
        case .array(let list): list.map(json)
        case .object(let object): object.mapValues(json)
        }
    }

    /// What the rules said, from its JSON; `unavailable` when it is none.
    public static func decodeSaid(_ value: Any) -> Said {
        guard let object = value as? [String: Any], let key = object["key"] as? String else { return Said(key: "unavailable") }
        return Said(key: key, args: object["args"] as? [String] ?? [], kind: object["kind"] as? String)
    }
}

extension Dictionary where Key == String, Value == Any {
    /// The entries whose value is not an empty optional, unwrapped: facts for the rules' JSON.
    public var compacted: [String: Any] {
        compactMapValues { value in
            let mirror = Mirror(reflecting: value)
            guard mirror.displayStyle == .optional else { return value }
            return mirror.children.first?.value
        }
    }
}
