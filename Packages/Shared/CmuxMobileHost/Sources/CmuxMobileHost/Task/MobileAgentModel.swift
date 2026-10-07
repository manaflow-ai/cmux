/// A model an agent offers, with the effort steps it accepts (task.schema.json `Agent.models`).
public struct MobileAgentModel: Hashable, Sendable, Codable {
    public var id: String
    public var label: String
    public var efforts: [String]
    public var defaultEffort: String?

    public init(id: String, label: String, efforts: [String] = [], defaultEffort: String? = nil) {
        self.id = id
        self.label = label
        self.efforts = efforts
        self.defaultEffort = defaultEffort
    }

    enum CodingKeys: String, CodingKey {
        case id, label, efforts
        case defaultEffort = "default_effort"
    }
}
