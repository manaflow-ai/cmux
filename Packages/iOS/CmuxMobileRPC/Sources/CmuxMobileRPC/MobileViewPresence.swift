/// Versioned presence for views currently attached to a runtime.
public struct MobileViewPresence: Decodable, Sendable, Equatable {
    /// The schema version of this presence object.
    public let version: Int
    /// Identified views, grouped by stable client identifier.
    public let views: [MobileAttachedView]

    private enum CodingKeys: String, CodingKey {
        case version
        case views
    }

    /// Decodes presence, accepting an early host that emits a version without view rows.
    /// - Parameter decoder: The decoder for the presence object.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        views = try container.decodeIfPresent([MobileAttachedView].self, forKey: .views) ?? []
    }
}
