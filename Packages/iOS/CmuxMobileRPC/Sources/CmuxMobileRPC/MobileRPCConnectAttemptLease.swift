import Foundation

struct MobileRPCConnectAttemptLease: Sendable, Equatable {
    static let untracked = Self(key: nil, id: UUID())

    let key: MobileRPCConnectAttemptKey?
    let id: UUID
}
