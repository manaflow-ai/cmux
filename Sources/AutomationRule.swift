import Foundation

/// A JSON value used by the automation configuration and action parameters.
///
/// Keeping configuration values typed makes rule matching deterministic while
/// still allowing an RPC action to pass any JSON object accepted by the v2
/// socket. The value is deliberately independent of ``JSONSerialization`` so
/// it can be used by both the app target and the bundled CLI target.
nonisolated enum AutomationJSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case integer(Int64)
    case double(Double)
    case string(String)
    case array([AutomationJSONValue])
    case object([String: AutomationJSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .integer(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([AutomationJSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: AutomationJSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported automation JSON value"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case .bool(let value):
            try container.encode(value)
        case .integer(let value):
            try container.encode(value)
        case .double(let value):
            try container.encode(value)
        case .string(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        }
    }

    /// Bridges the value into the Foundation shape accepted by the v2 encoder.
    var foundationObject: Any {
        switch self {
        case .null:
            return NSNull()
        case .bool(let value):
            return NSNumber(value: value)
        case .integer(let value):
            return NSNumber(value: value)
        case .double(let value):
            return NSNumber(value: value)
        case .string(let value):
            return value
        case .array(let values):
            return values.map(\.foundationObject)
        case .object(let values):
            return values.mapValues(\.foundationObject)
        }
    }

    /// Creates a configuration value from a JSONSerialization result.
    init?(foundationObject: Any) {
        switch foundationObject {
        case is NSNull:
            self = .null
        case let value as NSNumber:
            if CFGetTypeID(value) == CFBooleanGetTypeID() {
                self = .bool(value.boolValue)
            } else {
                let type = String(cString: value.objCType)
                if ["c", "C", "s", "S", "i", "I", "l", "L", "q", "Q"].contains(type) {
                    self = .integer(value.int64Value)
                } else {
                    self = .double(value.doubleValue)
                }
            }
        case let value as String:
            self = .string(value)
        case let value as [Any]:
            var result: [AutomationJSONValue] = []
            result.reserveCapacity(value.count)
            for item in value {
                guard let converted = AutomationJSONValue(foundationObject: item) else { return nil }
                result.append(converted)
            }
            self = .array(result)
        case let value as [String: Any]:
            var result: [String: AutomationJSONValue] = [:]
            result.reserveCapacity(value.count)
            for (key, item) in value {
                guard let converted = AutomationJSONValue(foundationObject: item) else { return nil }
                result[key] = converted
            }
            self = .object(result)
        default:
            return nil
        }
    }

    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    var doubleValue: Double? {
        switch self {
        case .integer(let value): return Double(value)
        case .double(let value): return value
        default: return nil
        }
    }

    var objectValue: [String: AutomationJSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    var arrayValue: [AutomationJSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }
}

nonisolated private struct AutomationCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init(stringValue: String) {
        self.stringValue = stringValue
        self.intValue = nil
    }

    init?(intValue: Int) {
        self.stringValue = String(intValue)
        self.intValue = intValue
    }
}

/// The event and category selectors that start a rule.
nonisolated struct AutomationWhen: Codable, Equatable, Sendable {
    let event: String?
    let category: String?

    init(event: String? = nil, category: String? = nil) {
        self.event = event
        self.category = category
    }

    init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer(),
           let event = try? single.decode(String.self) {
            self.init(event: event)
            return
        }
        let container = try decoder.container(keyedBy: AutomationCodingKey.self)
        self.init(
            event: try container.decodeIfPresent(String.self, forKey: AutomationCodingKey(stringValue: "event")),
            category: try container.decodeIfPresent(String.self, forKey: AutomationCodingKey(stringValue: "category"))
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: AutomationCodingKey.self)
        try container.encodeIfPresent(event, forKey: AutomationCodingKey(stringValue: "event"))
        try container.encodeIfPresent(category, forKey: AutomationCodingKey(stringValue: "category"))
    }

    var isEmpty: Bool { event == nil && category == nil }
}

/// One ordered action in an automation rule.
nonisolated struct AutomationAction: Codable, Equatable, Sendable {
    let action: String
    let parameters: [String: AutomationJSONValue]

    init(action: String, parameters: [String: AutomationJSONValue] = [:]) {
        self.action = action
        self.parameters = parameters
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AutomationCodingKey.self)
        guard let action = try container.decodeIfPresent(String.self, forKey: AutomationCodingKey(stringValue: "action")) else {
            throw DecodingError.keyNotFound(
                AutomationCodingKey(stringValue: "action"),
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Automation action is missing action")
            )
        }
        var parameters: [String: AutomationJSONValue] = [:]
        for key in container.allKeys where key.stringValue != "action" {
            if let value = try container.decodeIfPresent(AutomationJSONValue.self, forKey: key) {
                parameters[key.stringValue] = value
            }
        }
        self.init(action: action, parameters: parameters)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: AutomationCodingKey.self)
        try container.encode(action, forKey: AutomationCodingKey(stringValue: "action"))
        for (key, value) in parameters {
            try container.encode(value, forKey: AutomationCodingKey(stringValue: key))
        }
    }

    func value(for key: String) -> AutomationJSONValue? {
        parameters[key]
    }

    func string(for key: String) -> String? {
        value(for: key)?.stringValue
    }

    func bool(for key: String) -> Bool? {
        value(for: key)?.boolValue
    }

    func double(for key: String) -> Double? {
        value(for: key)?.doubleValue
    }

    func object(for key: String) -> [String: AutomationJSONValue]? {
        value(for: key)?.objectValue
    }
}

/// A configurable per-rule burst window.
nonisolated struct AutomationRateLimit: Codable, Equatable, Sendable {
    let intervalSeconds: TimeInterval
    let maximum: Int

    init(intervalSeconds: TimeInterval, maximum: Int = 1) {
        self.intervalSeconds = max(0.001, intervalSeconds)
        self.maximum = min(1_024, max(1, maximum))
    }

    init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer(),
           let seconds = try? single.decode(Double.self) {
            self.init(intervalSeconds: seconds)
            return
        }
        let container = try decoder.container(keyedBy: AutomationCodingKey.self)
        let interval = try container.decodeIfPresent(Double.self, forKey: AutomationCodingKey(stringValue: "interval_seconds"))
            ?? container.decodeIfPresent(Double.self, forKey: AutomationCodingKey(stringValue: "seconds"))
            ?? container.decodeIfPresent(Double.self, forKey: AutomationCodingKey(stringValue: "window"))
            ?? 1
        let maximum = try container.decodeIfPresent(Int.self, forKey: AutomationCodingKey(stringValue: "maximum"))
            ?? container.decodeIfPresent(Int.self, forKey: AutomationCodingKey(stringValue: "max"))
            ?? container.decodeIfPresent(Int.self, forKey: AutomationCodingKey(stringValue: "burst"))
            ?? container.decodeIfPresent(Int.self, forKey: AutomationCodingKey(stringValue: "count"))
            ?? 1
        self.init(intervalSeconds: interval, maximum: maximum)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: AutomationCodingKey.self)
        try container.encode(intervalSeconds, forKey: AutomationCodingKey(stringValue: "interval_seconds"))
        try container.encode(maximum, forKey: AutomationCodingKey(stringValue: "maximum"))
    }
}

/// A single config-file automation rule.
nonisolated struct AutomationRule: Codable, Equatable, Sendable, Identifiable {
    let id: String
    let when: AutomationWhen
    let predicates: [String: AutomationJSONValue]
    let actions: [AutomationAction]
    var enabled: Bool
    let rateLimit: AutomationRateLimit?

    /// The schema spelling of the predicate dictionary.
    var `where`: [String: AutomationJSONValue] { predicates }

    /// The schema spelling of the ordered action list.
    var `then`: [AutomationAction] { actions }

    /// Whether matching may need a live workspace status-tag snapshot.
    var usesWorkspaceTagPredicate: Bool {
        predicates.keys.contains { $0 == "workspace.tag" || $0 == "workspace_tag" }
    }

    init(
        id: String,
        when: AutomationWhen,
        predicates: [String: AutomationJSONValue] = [:],
        actions: [AutomationAction],
        enabled: Bool = true,
        rateLimit: AutomationRateLimit? = nil
    ) {
        self.id = id
        self.when = when
        self.predicates = predicates
        self.actions = actions
        self.enabled = enabled
        self.rateLimit = rateLimit
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AutomationCodingKey.self)
        guard let id = try container.decodeIfPresent(String.self, forKey: AutomationCodingKey(stringValue: "id")), !id.isEmpty else {
            throw DecodingError.keyNotFound(
                AutomationCodingKey(stringValue: "id"),
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Automation rule is missing id")
            )
        }
        let when = try container.decode(AutomationWhen.self, forKey: AutomationCodingKey(stringValue: "when"))
        let predicates = try container.decodeIfPresent(
            [String: AutomationJSONValue].self,
            forKey: AutomationCodingKey(stringValue: "where")
        ) ?? [:]
        let actions = try container.decode([AutomationAction].self, forKey: AutomationCodingKey(stringValue: "then"))
        let enabled = try container.decodeIfPresent(Bool.self, forKey: AutomationCodingKey(stringValue: "enabled")) ?? true
        let rateLimit = try container.decodeIfPresent(
            AutomationRateLimit.self,
            forKey: AutomationCodingKey(stringValue: "rate_limit")
        ) ?? container.decodeIfPresent(
            AutomationRateLimit.self,
            forKey: AutomationCodingKey(stringValue: "rate_limit_seconds")
        ) ?? container.decodeIfPresent(
            AutomationRateLimit.self,
            forKey: AutomationCodingKey(stringValue: "cooldown_seconds")
        )
        self.init(id: id, when: when, predicates: predicates, actions: actions, enabled: enabled, rateLimit: rateLimit)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: AutomationCodingKey.self)
        try container.encode(id, forKey: AutomationCodingKey(stringValue: "id"))
        try container.encode(when, forKey: AutomationCodingKey(stringValue: "when"))
        if !predicates.isEmpty {
            try container.encode(predicates, forKey: AutomationCodingKey(stringValue: "where"))
        }
        try container.encode(actions, forKey: AutomationCodingKey(stringValue: "then"))
        if !enabled {
            try container.encode(false, forKey: AutomationCodingKey(stringValue: "enabled"))
        }
        try container.encodeIfPresent(rateLimit, forKey: AutomationCodingKey(stringValue: "rate_limit"))
    }

    /// Returns whether the rule's selectors and predicates accept an event.
    func matches(event: [String: Any], workspaceTags: [String] = []) -> Bool {
        guard Self.matchesSelector(when.event, against: event["name"] as? String),
              Self.matchesSelector(when.category, against: event["category"] as? String) else {
            return false
        }
        for (path, expected) in predicates {
            guard let actual = Self.value(at: path, in: event, workspaceTags: workspaceTags),
                  Self.matchesValue(actual, expected: expected) else {
                return false
            }
        }
        return true
    }

    private static func matchesSelector(_ selector: String?, against actual: String?) -> Bool {
        guard let selector else { return true }
        guard let actual else { return false }
        let trimmed = selector.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if trimmed == "*" { return true }
        if trimmed.hasPrefix("*") && trimmed.hasSuffix("*") {
            return actual.localizedCaseInsensitiveContains(String(trimmed.dropFirst().dropLast()))
        }
        if trimmed.hasPrefix("*") {
            return actual.lowercased().hasSuffix(String(trimmed.dropFirst()).lowercased())
        }
        if trimmed.hasSuffix("*") {
            return actual.lowercased().hasPrefix(String(trimmed.dropLast()).lowercased())
        }
        return actual == trimmed
    }

    private static func value(
        at path: String,
        in event: [String: Any],
        workspaceTags: [String]
    ) -> AutomationJSONValue? {
        let payload = event["payload"] as? [String: Any] ?? [:]
        switch path {
        case "workspace.tag", "workspace_tag":
            var knownTags = workspaceTags
            if let tags = payload["tags"] {
                if let dictionaries = tags as? [[String: Any]] {
                    for tag in dictionaries {
                        if let key = tag["key"] as? String { knownTags.append(key) }
                        if let value = tag["value"] as? String, !value.isEmpty { knownTags.append(value) }
                    }
                } else if let value = AutomationJSONValue(foundationObject: tags) {
                    return knownTags.isEmpty ? value : .array(knownTags.map(AutomationJSONValue.string) + [value])
                }
            }
            for key in ["workspace_tag", "tag"] {
                if let value = payload[key], let string = value as? String {
                    knownTags.append(string)
                }
            }
            return knownTags.isEmpty ? nil : .array(Array(Set(knownTags)).map(AutomationJSONValue.string))
        case "workspace.title", "title":
            for key in ["title", "custom_title", "workspace_title"] {
                if let value = payload[key] ?? event[key],
                   let converted = AutomationJSONValue(foundationObject: value) {
                    return converted
                }
            }
            return nil
        case "agent":
            for key in ["agent", "_source", "source"] {
                if let value = payload[key] ?? event[key], let converted = AutomationJSONValue(foundationObject: value) {
                    return converted
                }
            }
            return nil
        case "surface.kind", "surface_kind":
            for key in ["kind", "type", "surface_kind"] {
                if let value = payload[key] ?? event[key],
                   let converted = AutomationJSONValue(foundationObject: value) {
                    return converted
                }
            }
            return nil
        default:
            if let direct = payload[path], let converted = AutomationJSONValue(foundationObject: direct) {
                return converted
            }
            return Self.nestedValue(path: path, payload: payload) ?? Self.nestedValue(path: path, payload: event)
        }
    }

    private static func nestedValue(path: String, payload: [String: Any]) -> AutomationJSONValue? {
        let components = path.split(separator: ".").map(String.init)
        guard !components.isEmpty else { return nil }
        var current: Any = payload
        for component in components {
            guard let object = current as? [String: Any], let next = object[component] else {
                return nil
            }
            current = next
        }
        return AutomationJSONValue(foundationObject: current)
    }

    private static func matchesValue(_ actual: AutomationJSONValue, expected: AutomationJSONValue) -> Bool {
        if let expectedArray = expected.arrayValue {
            return expectedArray.contains { matchesValue(actual, expected: $0) }
        }
        if let operators = expected.objectValue, !operators.isEmpty,
           operators.keys.contains(where: { ["equals", "contains", "prefix", "suffix", "in", "not"].contains($0) }) {
            if let value = operators["equals"] { return matchesValue(actual, expected: value) }
            if let value = operators["contains"] {
                if let actualString = actual.stringValue, let expectedString = value.stringValue {
                    return actualString.localizedCaseInsensitiveContains(expectedString)
                }
                if let actualArray = actual.arrayValue {
                    return actualArray.contains { matchesValue($0, expected: value) }
                }
            }
            if let value = operators["prefix"], let actualString = actual.stringValue, let expectedString = value.stringValue {
                return actualString.hasPrefix(expectedString)
            }
            if let value = operators["suffix"], let actualString = actual.stringValue, let expectedString = value.stringValue {
                return actualString.hasSuffix(expectedString)
            }
            if let values = operators["in"]?.arrayValue {
                return values.contains { matchesValue(actual, expected: $0) }
            }
            if let value = operators["not"] {
                return !matchesValue(actual, expected: value)
            }
            return false
        }
        if let actualArray = actual.arrayValue {
            return actualArray.contains { matchesValue($0, expected: expected) }
        }
        switch (actual, expected) {
        case (.string(let lhs), .string(let rhs)):
            return lhs == rhs
        case (.bool(let lhs), .bool(let rhs)):
            return lhs == rhs
        case (.bool(let lhs), .string(let rhs)):
            return lhs == ["true", "1", "yes"].contains(rhs.lowercased())
        case (.string(let lhs), .bool(let rhs)):
            return ["true", "1", "yes"].contains(lhs.lowercased()) == rhs
        case (.integer(let lhs), .integer(let rhs)):
            return lhs == rhs
        case (.integer(let lhs), .double(let rhs)):
            return Double(lhs) == rhs
        case (.double(let lhs), .integer(let rhs)):
            return lhs == Double(rhs)
        case (.double(let lhs), .double(let rhs)):
            return lhs == rhs
        case (.null, .null):
            return true
        default:
            return false
        }
    }
}

/// The versioned top-level automation configuration.
nonisolated struct AutomationConfiguration: Codable, Equatable, Sendable {
    static let currentVersion = 1

    let version: Int
    var rules: [AutomationRule]

    init(version: Int = AutomationConfiguration.currentVersion, rules: [AutomationRule] = []) {
        self.version = version
        self.rules = rules
    }
}
