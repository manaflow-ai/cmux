import Foundation

/// Token that reports deallocation of a pre-session pasteboard writer.
@MainActor
final class ProvisionalDragWriterOwnershipToken {
    let id: UUID
    private let onDeallocated: @MainActor (UUID) -> Void

    init(onDeallocated: @escaping @MainActor (UUID) -> Void) {
        id = UUID()
        self.onDeallocated = onDeallocated
    }

    /// Reports deallocation synchronously on the main actor when possible.
    nonisolated func notifyDeallocated() {
        let tokenID = id
        let callback = onDeallocated
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                callback(tokenID)
            }
        } else {
            Task { @MainActor in
                callback(tokenID)
            }
        }
    }

    deinit {
        notifyDeallocated()
    }
}
