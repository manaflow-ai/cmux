import Foundation

struct MobileCoreRPCPendingWrite: Sendable {
    let id: UUID
    let requestID: String
    let frame: Data
    let authorizeSend: (@Sendable () async throws -> MobileRPCAuthScope.SendLease)?
}
