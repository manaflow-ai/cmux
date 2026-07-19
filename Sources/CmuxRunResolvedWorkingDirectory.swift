import Foundation

struct CmuxRunResolvedWorkingDirectory: Equatable, Sendable {
    let path: String
    let identity: CmuxRunWorkingDirectoryIdentity
}
