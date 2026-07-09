import Foundation

/// The decoded `hooks` section of `~/.config/cmux/cmux.json`.
public struct CmuxHooksConfig: Codable, Sendable, Equatable {
    /// The optional blocking pre-spawn hook.
    public let preSpawn: CmuxHookDefinition?

    /// Event hooks keyed by exact event-bus event name.
    public let events: [String: [CmuxHookDefinition]]

    /// Creates a hooks configuration.
    /// - Parameters:
    ///   - preSpawn: The optional pre-spawn hook definition.
    ///   - events: Event hook definitions keyed by exact event name.
    public init(preSpawn: CmuxHookDefinition? = nil, events: [String: [CmuxHookDefinition]] = [:]) {
        self.preSpawn = preSpawn
        self.events = events
    }

    private enum CodingKeys: String, CodingKey {
        case preSpawn
        case events
    }

    /// Creates a hooks configuration from JSON.
    /// - Parameter decoder: The decoder containing the `hooks` section.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        preSpawn = try container.decodeIfPresent(
            CmuxHookDefinition.self,
            forKey: .preSpawn,
            defaultTimeoutMs: CmuxHookDefinition.defaultPreSpawnTimeoutMs
        )
        events = try container.decodeEventHooks(
            forKey: .events,
            defaultTimeoutMs: CmuxHookDefinition.defaultEventTimeoutMs
        ) ?? [:]
    }

    /// Encodes the hooks configuration.
    /// - Parameter encoder: The target encoder.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(preSpawn, forKey: .preSpawn)
        try container.encode(events, forKey: .events)
    }
}

extension KeyedDecodingContainer {
    func decodeIfPresent(
        _ type: CmuxHookDefinition.Type,
        forKey key: Key,
        defaultTimeoutMs: Int
    ) throws -> CmuxHookDefinition? {
        guard contains(key) else { return nil }
        let decoder = try superDecoder(forKey: key)
        return try CmuxHookDefinition(from: decoder, defaultTimeoutMs: defaultTimeoutMs)
    }

    func decodeEventHooks(
        forKey key: Key,
        defaultTimeoutMs: Int
    ) throws -> [String: [CmuxHookDefinition]]? {
        guard contains(key) else { return nil }
        let decoder = try superDecoder(forKey: key)
        let container = try decoder.container(keyedBy: DynamicCodingKey.self)
        var result: [String: [CmuxHookDefinition]] = [:]
        for eventKey in container.allKeys {
            var hooks = try container.nestedUnkeyedContainer(forKey: eventKey)
            var definitions: [CmuxHookDefinition] = []
            while !hooks.isAtEnd {
                let hookDecoder = try hooks.superDecoder()
                definitions.append(
                    try CmuxHookDefinition(from: hookDecoder, defaultTimeoutMs: defaultTimeoutMs)
                )
            }
            result[eventKey.stringValue] = definitions
        }
        return result
    }
}
