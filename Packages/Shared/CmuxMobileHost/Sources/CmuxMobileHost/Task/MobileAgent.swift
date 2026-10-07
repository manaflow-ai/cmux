/// An agent harness this Mac offers to phones (acpmux `_acpmux/harnesses` +
/// `_acpmux/models`, task.schema.json `Agent`). The only harness ids a
/// dispatch may name.
public struct MobileAgent: Hashable, Sendable, Codable {
    public var id: String
    public var name: String
    public var models: [MobileAgentModel]
    public var defaultModel: String?
    /// acpmux's reason when the harness cannot run ("Not signed in"); nil when it can.
    public var unavailable: String?

    public init(id: String, name: String, models: [MobileAgentModel] = [], defaultModel: String? = nil,
                unavailable: String? = nil) {
        self.id = id
        self.name = name
        self.models = models
        self.defaultModel = defaultModel
        self.unavailable = unavailable
    }

    enum CodingKeys: String, CodingKey {
        case id, name, models, unavailable
        case defaultModel = "default_model"
    }

    public func model(_ id: String) -> MobileAgentModel? { models.first { $0.id == id } }
}
