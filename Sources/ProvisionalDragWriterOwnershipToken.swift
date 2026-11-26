import Foundation

/// Token that reports deallocation of a pre-session pasteboard writer.
@MainActor
final class ProvisionalDragWriterOwnershipToken {
    let id: UUID
    // A global-actor-isolated function value is safe to copy from the
    // nonisolated deinit path. Invocation still hops to the main actor below.
    nonisolated private let onDeallocated: @MainActor (UUID) -> Void

    init(onDeallocated: @escaping @MainActor (UUID) -> Void) {
        id = UUID()
        self.onDeallocated = onDeallocated
    }

    /// Reports deallocation on a separate main-actor turn.
    nonisolated func notifyDeallocated() {
        let tokenID = id
        let callback = onDeallocated
        // Never re-enter AppKit or SwiftUI teardown from ARC deallocation.
        // The callback captures only value/closure locals, not this token.
        Task { @MainActor in
            callback(tokenID)
        }
    }

    deinit {
        notifyDeallocated()
    }
}
