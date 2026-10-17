public import Foundation

/// The exact ready control transport observed by a registry's connected event.
public nonisolated struct DaemonControlStamp: Sendable, Hashable {
    /// Connection instance, distinct even when a replacement starts at serial one.
    public let sourceID: UUID
    /// Ready serial admitted by the original connected event.
    public let serial: UInt64

    /// Captures only a stamped connected event; snapshots and other events cannot admit a carrier.
    /// - Parameter envelope: The original event applied by the store.
    public init?(_ envelope: DaemonEventEnvelope) {
        guard case .connected = envelope.event, let sourceID = envelope.sourceID, envelope.connectionSerial > 0 else { return nil }
        self.sourceID = sourceID; serial = envelope.connectionSerial
    }
}
