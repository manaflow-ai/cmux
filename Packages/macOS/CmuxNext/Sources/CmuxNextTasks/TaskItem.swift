import Foundation

public nonisolated struct TaskItem: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var key: String
    public var number: Int
    public var title: String
    public var status: String
    public var category: TaskCategory
    public var priority: TaskPriority
    public var assignee: TaskPrincipal?
    public var delegate: TaskAgent?
    public var labels: [String]
    public var project: String?
    public var sortKey: String
    public var attention: TaskAttention?
    public var updatedAt: Int64
    public var archived: Bool
    public var deleted: Bool

    enum CodingKeys: String, CodingKey {
        case id, key, number, title, status, category, priority, assignee, delegate, labels, project, attention, archived, deleted
        case sortKey = "sort_key"
        case updatedAt = "updated_at"
    }

    /// Decodes both the owner's task view (with `key`, `category`) and a raw
    /// task entity from an event (the model fills `key` and `category`).
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        number = try c.decode(Int.self, forKey: .number)
        key = try c.decodeIfPresent(String.self, forKey: .key) ?? "#\(number)"
        title = try c.decode(String.self, forKey: .title)
        status = try c.decode(String.self, forKey: .status)
        category = try c.decodeIfPresent(TaskCategory.self, forKey: .category) ?? .backlog
        priority = try c.decodeIfPresent(TaskPriority.self, forKey: .priority) ?? .none
        assignee = try c.decodeIfPresent(TaskPrincipal.self, forKey: .assignee)
        delegate = try c.decodeIfPresent(TaskAgent.self, forKey: .delegate)
        labels = try c.decodeIfPresent([String].self, forKey: .labels) ?? []
        project = try c.decodeIfPresent(String.self, forKey: .project)
        sortKey = try c.decode(String.self, forKey: .sortKey)
        attention = try c.decodeIfPresent(TaskAttention.self, forKey: .attention)
        updatedAt = try c.decodeIfPresent(Int64.self, forKey: .updatedAt) ?? 0
        archived = try c.decodeIfPresent(Bool.self, forKey: .archived) ?? false
        deleted = try c.decodeIfPresent(Bool.self, forKey: .deleted) ?? false
    }

    public init(id: String, key: String, number: Int, title: String, status: String, category: TaskCategory,
                priority: TaskPriority = .none, assignee: TaskPrincipal? = nil, delegate: TaskAgent? = nil,
                labels: [String] = [], project: String? = nil, sortKey: String, attention: TaskAttention? = nil,
                updatedAt: Int64 = 0, archived: Bool = false, deleted: Bool = false) {
        self.id = id
        self.key = key
        self.number = number
        self.title = title
        self.status = status
        self.category = category
        self.priority = priority
        self.assignee = assignee
        self.delegate = delegate
        self.labels = labels
        self.project = project
        self.sortKey = sortKey
        self.attention = attention
        self.updatedAt = updatedAt
        self.archived = archived
        self.deleted = deleted
    }
}
