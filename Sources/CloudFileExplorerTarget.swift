import CmuxAuthRuntime
import Foundation

/// Credential-free authority carried by every Cloud filesystem request and result.
struct CloudFileExplorerTarget: Equatable, Sendable {
    typealias Identity = CloudFileExplorerTargetIdentity
    let identity: Identity
    let isCurrent: @MainActor @Sendable () -> Bool

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.identity == rhs.identity }

    @MainActor
    func validate(vmID: String) throws {
        guard vmID == identity.vmID, isCurrent() else { throw FileExplorerError.providerUnavailable }
    }
}
