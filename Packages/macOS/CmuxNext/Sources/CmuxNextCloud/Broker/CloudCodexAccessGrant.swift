public import Foundation

/// The access-only credential delivered to a VM. The refresh token never enters
/// this value, the VM, a log, or a process argument.
nonisolated public struct CloudCodexAccessGrant: Sendable, Equatable {
    public let accessToken: String
    public let chatgptAccountID: String
    public let expiresAt: Date

    nonisolated public init(accessToken: String, chatgptAccountID: String, expiresAt: Date) {
        self.accessToken = accessToken
        self.chatgptAccountID = chatgptAccountID
        self.expiresAt = expiresAt
    }
}

