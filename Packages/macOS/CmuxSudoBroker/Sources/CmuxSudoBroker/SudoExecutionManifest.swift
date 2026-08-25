import Foundation

struct SudoExecutionManifest: Codable, Sendable, Equatable {
    let id: String
    let requesterIdentity: SudoProcessIdentity
    let currentDirectory: String
    let directoryIdentity: SudoDirectoryIdentity?
    let deadline: Date

    init(
        id: String,
        requesterIdentity: SudoProcessIdentity,
        currentDirectory: String,
        directoryIdentity: SudoDirectoryIdentity? = nil,
        deadline: Date
    ) {
        self.id = id
        self.requesterIdentity = requesterIdentity
        self.currentDirectory = currentDirectory
        self.directoryIdentity = directoryIdentity
        self.deadline = deadline
    }

    private enum CodingKeys: String, CodingKey {
        case id, requesterIdentity, currentDirectory, directoryIdentity, deadline
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        requesterIdentity = try container.decode(SudoProcessIdentity.self, forKey: .requesterIdentity)
        currentDirectory = try container.decode(String.self, forKey: .currentDirectory)
        directoryIdentity = try container.decodeIfPresent(
            SudoDirectoryIdentity.self,
            forKey: .directoryIdentity
        )
        deadline = try container.decode(Date.self, forKey: .deadline)
    }
}
