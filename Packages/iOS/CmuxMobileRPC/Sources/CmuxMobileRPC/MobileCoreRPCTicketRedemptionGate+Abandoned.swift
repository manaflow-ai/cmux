import CMUXMobileCore
import Foundation

extension MobileCoreRPCTicketRedemptionGate {
    /// A superseded redemption the gate retains only so it can cancel it: a
    /// non-cooperative provider that ignores cancellation keeps `task` alive,
    /// so the gate holds it (and its `completionObserver`) until the next
    /// abandonment drops it, bounding retained work to the latest attempt.
    struct Abandoned {
        var task: Task<CmxAttachTicket, any Error>
        var completionObserver: Task<Void, Never>?
    }
}
