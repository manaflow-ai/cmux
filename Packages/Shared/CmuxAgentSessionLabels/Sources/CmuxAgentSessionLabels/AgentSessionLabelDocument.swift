import Foundation

/// The on-disk shape of the labels file.
///
/// Records nest under their agent rather than under one composite key, so a
/// session id is never parsed out of a string, whatever characters it holds.
struct AgentSessionLabelDocument: Codable, Equatable {
    /// The schema version, so a later shape can be told from this one.
    static let currentVersion = 1

    struct Record: Codable, Equatable {
        var label: String
        var updatedAt: Date

        enum CodingKeys: String, CodingKey {
            case label
            case updatedAt = "updated_at"
        }
    }

    var version: Int
    var agents: [String: [String: Record]]

    init(version: Int = AgentSessionLabelDocument.currentVersion,
         agents: [String: [String: Record]] = [:]) {
        self.version = version
        self.agents = agents
    }
}
