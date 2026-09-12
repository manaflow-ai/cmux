import Foundation

/// An immutable, coherent revision of a ``JSONConfigStore`` file.
///
/// The store creates one snapshot after each observed or completed write. The
/// raw JSON bytes are `Sendable`, so consumers can decode the revision on their
/// own actor without sharing the store's mutable Foundation object graph.
public struct JSONConfigStoreSnapshot: Equatable, Sendable {
    /// Canonical JSON bytes for the complete configuration root.
    public let data: Data

    /// Monotonically increasing content revision within the originating store.
    public let revision: UInt64

    /// Creates an immutable store snapshot.
    ///
    /// - Parameters:
    ///   - data: Canonical or otherwise valid JSON object bytes.
    ///   - revision: Store-assigned ordering metadata; zero for standalone snapshots.
    public init(data: Data, revision: UInt64 = 0) {
        self.data = data
        self.revision = revision
    }
}
