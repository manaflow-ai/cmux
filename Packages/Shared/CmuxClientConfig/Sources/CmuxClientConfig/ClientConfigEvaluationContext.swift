/// Extra evaluation data forwarded to PostHog by `/api/client-config`.
public struct ClientConfigEvaluationContext: Encodable, Sendable, Equatable {
    /// Group keys, such as organization id, used for group-level flag evaluation.
    public let groups: [String: ClientConfigJSONValue]
    /// Person properties attached to this evaluation request.
    public let personProperties: [String: ClientConfigJSONValue]
    /// Group properties attached to this evaluation request.
    public let groupProperties: [String: ClientConfigJSONValue]
    /// The anonymous install or browser id, when distinct from the current user id.
    public let anonDistinctId: String?
    /// The device id used by the client, when available.
    public let deviceId: String?
    /// The IANA timezone name, when available.
    public let timezone: String?
    /// PostHog evaluation contexts or environments to include.
    public let evaluationContexts: [String]

    /// Creates an evaluation context.
    public init(
        groups: [String: ClientConfigJSONValue] = [:],
        personProperties: [String: ClientConfigJSONValue] = [:],
        groupProperties: [String: ClientConfigJSONValue] = [:],
        anonDistinctId: String? = nil,
        deviceId: String? = nil,
        timezone: String? = nil,
        evaluationContexts: [String] = []
    ) {
        self.groups = groups
        self.personProperties = personProperties
        self.groupProperties = groupProperties
        self.anonDistinctId = anonDistinctId
        self.deviceId = deviceId
        self.timezone = timezone
        self.evaluationContexts = evaluationContexts
    }

    enum CodingKeys: String, CodingKey {
        case groups
        case personProperties
        case groupProperties
        case anonDistinctId
        case deviceId
        case timezone
        case evaluationContexts
    }

    /// Encodes only populated context fields so the web route sees the same sparse shape as browser callers.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if !groups.isEmpty { try container.encode(groups, forKey: .groups) }
        if !personProperties.isEmpty { try container.encode(personProperties, forKey: .personProperties) }
        if !groupProperties.isEmpty { try container.encode(groupProperties, forKey: .groupProperties) }
        try container.encodeIfPresent(anonDistinctId, forKey: .anonDistinctId)
        try container.encodeIfPresent(deviceId, forKey: .deviceId)
        try container.encodeIfPresent(timezone, forKey: .timezone)
        if !evaluationContexts.isEmpty { try container.encode(evaluationContexts, forKey: .evaluationContexts) }
    }
}
