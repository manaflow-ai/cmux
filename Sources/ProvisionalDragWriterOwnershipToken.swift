import Foundation

/// Token that reports deallocation of a pre-session pasteboard writer.
@MainActor
final class ProvisionalDragWriterOwnershipToken {
    // These immutable values are safe to read from ARC's nonisolated deinit:
    // UUID is Sendable and the callback is explicitly isolated and Sendable.
    nonisolated let id: UUID
    nonisolated private let onDeallocated: @MainActor @Sendable (UUID) -> Void

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
