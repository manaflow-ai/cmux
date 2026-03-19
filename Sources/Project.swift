import Foundation
import Combine

/// A project groups multiple task-workspaces under a shared project directory.
/// Projects are sidebar-only containers — they don't have their own Bonsplit or panels.
final class Project: ObservableObject, Identifiable, Codable {
    let id: UUID
    @Published var name: String
    @Published var directory: String
    @Published var workspaceIds: [UUID]
    @Published var isExpanded: Bool

    init(id: UUID = UUID(), name: String, directory: String) {
        self.id = id
        self.name = name
        self.directory = directory
        self.workspaceIds = []
        self.isExpanded = true
    }

    // MARK: - Codable

    enum CodingKeys: String, CodingKey {
        case id, name, directory, workspaceIds, isExpanded
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.name = try container.decode(String.self, forKey: .name)
        self.directory = try container.decode(String.self, forKey: .directory)
        self.workspaceIds = try container.decodeIfPresent([UUID].self, forKey: .workspaceIds) ?? []
        self.isExpanded = try container.decodeIfPresent(Bool.self, forKey: .isExpanded) ?? true
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(directory, forKey: .directory)
        try container.encode(workspaceIds, forKey: .workspaceIds)
        try container.encode(isExpanded, forKey: .isExpanded)
    }
}
