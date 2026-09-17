import Foundation

/// Lock-published persistence intents so session snapshots can read a fresh
/// coordinator value without awaiting the actor.
final class NestedPersistenceIntentBox: @unchecked Sendable {
    private let lock = NSLock()
    private var intents: [UUID: NestedAttachmentIntentDescriptor] = [:]

    /// Replaces the published intent map.
    ///
    /// - Parameter next: Complete host-surface → intent mapping to publish.
    func replace(_ next: [UUID: NestedAttachmentIntentDescriptor]) {
        lock.lock()
        intents = next
        lock.unlock()
    }

    /// Returns the published intent for one host surface, if any.
    ///
    /// - Parameter hostStableSurfaceID: Host terminal surface whose intent to read.
    /// - Returns: The latest published intent, or `nil` when none is published.
    func intent(for hostStableSurfaceID: UUID) -> NestedAttachmentIntentDescriptor? {
        lock.lock()
        defer { lock.unlock() }
        return intents[hostStableSurfaceID]
    }
}
