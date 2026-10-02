import CmuxAuthRuntime
import Foundation

/// The credential-free identity used to validate one Cloud filesystem target.
struct CloudFileExplorerTargetIdentity: Equatable, Sendable {
    let workspaceID: UUID
    let vmID: String
    let remoteWorkspaceID: String?
    let team: AuthenticatedTeamScope
    let provider: ObjectIdentifier
}
