import Foundation

struct WorkspaceLinkTitleFetchRequest: Sendable {
    let entry: WorkspaceCapturedLink
    let requestID: UUID
}
