import Foundation

struct AgentConversationForkExecutableBindingAdjacentCopy: Equatable, Hashable, Sendable {
    let stagingPath: String
    let cleanupRecordPath: String
    let cleanupDirectoryPath: String
    let expectedCleanupDirectoryStatSignature: String
    let cleanupRecordContents: String
}
