import Foundation

/// JSON values used by the language-neutral plugin wire contract.
public indirect enum CmuxExtensionJSONValue: Codable, Equatable, Hashable, Sendable {
    /// JSON `null`.
    case null
    /// A JSON boolean.
    case bool(Bool)
    /// A finite JSON number.
    case number(Double)
    /// A JSON string.
    case string(String)
    /// A JSON array.
    case array([CmuxExtensionJSONValue])
    /// A JSON object with string keys.
    case object([String: CmuxExtensionJSONValue])

    /// Converts a Foundation JSON object into a sendable wire value.
    public init(foundationValue: Any) {
        switch foundationValue {
        case is NSNull:
            self = .null
        case let value as Bool:
            self = .bool(value)
        case let value as NSNumber:
            let number = value.doubleValue
            self = number.isFinite ? .number(number) : .null
        case let value as String:
            self = .string(value)
        case let value as [Any]:
            self = .array(value.map(Self.init(foundationValue:)))
        case let value as [String: Any]:
            self = .object(value.mapValues(Self.init(foundationValue:)))
        default:
            self = .null
        }
    }

    /// Converts this value into a Foundation JSON-compatible object.
    public var foundationValue: Any {
        switch self {
        case .null:
            return NSNull()
        case .bool(let value):
            return value
        case .number(let value):
            return NSNumber(value: value)
        case .string(let value):
            return value
        case .array(let values):
            return values.map(\.foundationValue)
        case .object(let values):
            return values.mapValues(\.foundationValue)
        }
    }

    /// Encodes the same untagged JSON representation used by the cmux event
    /// stream, so a plugin can decode payloads with any standard JSON library.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case .bool(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .string(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        }
    }

    /// Decodes an untagged JSON value and rejects non-finite numbers.
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            guard value.isFinite else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "plugin JSON numbers must be finite"
                )
            }
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([Self].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: Self].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "unsupported plugin JSON value"
            )
        }
    }
}

/// A canonical event envelope delivered by the existing `cmux-events` stream.
public struct CmuxPluginEventEnvelope: Codable, Equatable, Sendable {
    /// Stream record type, normally `event`.
    public let type: String
    /// Event protocol name from the wire's `protocol` field.
    public let protocolName: String
    /// Event-stream protocol version.
    public let version: Int
    /// Identifier for the current host process lifetime.
    public let bootID: String
    /// Monotonic sequence number within the current boot.
    public let sequence: Int64
    /// Stable event identifier derived from boot and sequence.
    public let id: String
    /// Canonical event name.
    public let name: String
    /// Broad event category.
    public let category: String
    /// Host component that emitted the event.
    public let source: String
    /// ISO-8601 event timestamp.
    public let occurredAt: String
    /// Related workspace identifier, when present.
    public let workspaceID: String?
    /// Related surface identifier, when present.
    public let surfaceID: String?
    /// Related pane identifier, when present.
    public let paneID: String?
    /// Related window identifier, when present.
    public let windowID: String?
    /// Event-specific JSON fields.
    public let payload: [String: CmuxExtensionJSONValue]

    /// Creates an event envelope.
    public init(
        type: String = "event",
        protocolName: String = "cmux-events",
        version: Int = 1,
        bootID: String,
        sequence: Int64,
        id: String,
        name: String,
        category: String,
        source: String,
        occurredAt: String,
        workspaceID: String? = nil,
        surfaceID: String? = nil,
        paneID: String? = nil,
        windowID: String? = nil,
        payload: [String: CmuxExtensionJSONValue] = [:]
    ) {
        self.type = type
        self.protocolName = protocolName
        self.version = version
        self.bootID = bootID
        self.sequence = sequence
        self.id = id
        self.name = name
        self.category = category
        self.source = source
        self.occurredAt = occurredAt
        self.workspaceID = workspaceID
        self.surfaceID = surfaceID
        self.paneID = paneID
        self.windowID = windowID
        self.payload = payload
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case protocolName = "protocol"
        case version
        case bootID = "boot_id"
        case sequence = "seq"
        case id
        case name
        case category
        case source
        case occurredAt = "occurred_at"
        case workspaceID = "workspace_id"
        case surfaceID = "surface_id"
        case paneID = "pane_id"
        case windowID = "window_id"
        case payload
    }
}

/// A plugin's request to consume the already-authenticated event stream.
public struct CmuxPluginSubscriptionRequest: Codable, Equatable, Sendable {
    /// Plugin identifier from the validated manifest.
    public let pluginID: String
    /// In-memory capability token supplied by the host.
    public let token: String
    /// Last processed stream sequence, for replay when available.
    public let afterSequence: Int64?
    /// Requested event names, or an empty array for all granted names.
    public let eventNames: [String]
    /// Whether the host should send idle heartbeat records.
    public let includeHeartbeats: Bool

    /// Creates a subscription request.
    public init(
        pluginID: String,
        token: String,
        afterSequence: Int64? = nil,
        eventNames: [String] = [],
        includeHeartbeats: Bool = true
    ) {
        self.pluginID = pluginID
        self.token = token
        self.afterSequence = afterSequence
        self.eventNames = eventNames
        self.includeHeartbeats = includeHeartbeats
    }

    private enum CodingKeys: String, CodingKey {
        case pluginID = "plugin_id"
        case token = "plugin_token"
        case afterSequence = "after_seq"
        case eventNames = "names"
        case includeHeartbeats = "include_heartbeats"
    }
}

/// The action invocation event published for a plugin palette command.
public struct CmuxPluginActionInvocation: Codable, Equatable, Sendable {
    /// Plugin that owns the invoked action.
    public let pluginID: String
    /// Plugin-local action identifier.
    public let actionID: String
    /// Unique identifier plugins can use for deduplication.
    public let invocationID: String
    /// ISO-8601 invocation timestamp.
    public let occurredAt: String
    /// Optional invocation context supplied by the host.
    public let context: [String: CmuxExtensionJSONValue]

    /// Creates an action invocation.
    public init(
        pluginID: String,
        actionID: String,
        invocationID: String = UUID().uuidString,
        occurredAt: String,
        context: [String: CmuxExtensionJSONValue] = [:]
    ) {
        self.pluginID = pluginID
        self.actionID = actionID
        self.invocationID = invocationID
        self.occurredAt = occurredAt
        self.context = context
    }

    /// Event-bus name used for action delivery.
    public static let eventName = "plugin.action.invoked"

    private enum CodingKeys: String, CodingKey {
        case pluginID = "plugin_id"
        case actionID = "action_id"
        case invocationID = "invocation_id"
        case occurredAt = "occurred_at"
        case context
    }
}

/// Pure authorization helper shared by the host and plugin-facing tests.
public struct CmuxPluginSubscriptionPolicy: Equatable, Sendable {
    /// Plugin to which this policy applies.
    public let pluginID: String
    /// Canonical and compatibility event names the grant permits.
    public let allowedEventNames: Set<String>
    /// Plugin-local action identifiers the grant permits.
    public let allowedActionIDs: Set<String>

    /// Creates a policy from effective permissions.
    public init(pluginID: String, permissions: CmuxPluginPermissions) {
        self.pluginID = pluginID
        var eventNames = permissions.enabled && permissions.pluginScopes.contains(.eventHooks)
            ? Set(permissions.events.flatMap(\.acceptedWireNames))
            : []
        if permissions.enabled && permissions.pluginScopes.contains(.paletteActions) {
            eventNames.insert(CmuxPluginActionInvocation.eventName)
        }
        self.allowedEventNames = eventNames
        self.allowedActionIDs = permissions.enabled && permissions.pluginScopes.contains(.paletteActions)
            ? permissions.actions
            : []
    }

    /// Whether the event name is authorized for this plugin.
    public func allowsEvent(name: String) -> Bool {
        allowedEventNames.contains(name)
    }

    /// Whether the action is authorized for this plugin.
    public func allowsAction(id: String) -> Bool {
        allowedActionIDs.contains(id)
    }
}
