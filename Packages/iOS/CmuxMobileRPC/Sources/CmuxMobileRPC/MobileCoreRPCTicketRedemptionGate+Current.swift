import CMUXMobileCore
import Foundation

extension MobileCoreRPCTicketRedemptionGate {
    /// The in-flight redemption shared by every current waiter: the provider
    /// `task`, its completion observer, the live `waiters` count, and the
    /// timed-out bookkeeping the gate uses to reset or supersede the attempt.
    struct Current {
        var id: UUID
        var task: Task<CmxAttachTicket, any Error>
        var completionObserver: Task<Void, Never>?
        var waiters: Int
        var timedOutUntil: UInt64?
        var isCompleted: Bool
    }
}
