import Foundation

struct SudoExecutionManifest: Codable, Sendable, Equatable {
    let id: String
    let requesterIdentity: SudoProcessIdentity
    let currentDirectory: String
    let directoryIdentity: SudoDirectoryIdentity?
    let deadline: Date
    /// Lowercase hex SHA-256 of the exact script bytes the user reviewed and approved.
    let reviewedScriptSHA256: String?

    init(
        id: String,
        requesterIdentity: SudoProcessIdentity,
        currentDirectory: String,
        directoryIdentity: SudoDirectoryIdentity? = nil,
        deadline: Date,
        reviewedScriptSHA256: String? = nil
    ) {
        self.id = id
        self.requesterIdentity = requesterIdentity
        self.currentDirectory = currentDirectory
        self.directoryIdentity = directoryIdentity
        self.deadline = deadline
        self.reviewedScriptSHA256 = reviewedScriptSHA256
    }

    private enum CodingKeys: String, CodingKey {
        case id, requesterIdentity, currentDirectory, directoryIdentity, deadline
        case reviewedScriptSHA256
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
        reviewedScriptSHA256 = try container.decodeIfPresent(
            String.self,
            forKey: .reviewedScriptSHA256
        )
    }
}
