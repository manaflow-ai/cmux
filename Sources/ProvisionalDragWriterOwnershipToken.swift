import Foundation

/// Token that reports deallocation of a pre-session pasteboard writer.
@MainActor
final class ProvisionalDragWriterOwnershipToken {
    // These immutable values are Sendable so ARC can copy them from the
    // nonisolated deinitializer before handing the callback back to the main
    // actor.
    nonisolated let id: UUID
    // The callback is immutable and only ever invoked from a main-actor Task;
    // ARC may read this one property from an arbitrary executor during deinit.
    private nonisolated let onDeallocated: @MainActor @Sendable (UUID) -> Void

    init(onDeallocated: @escaping @MainActor @Sendable (UUID) -> Void) {
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
