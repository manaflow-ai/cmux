import Foundation

/// An immutable, coherent revision of a ``JSONConfigStore`` file.
///
/// The store creates one snapshot after each observed or completed write. The
/// raw JSON bytes are `Sendable`, so consumers can decode the revision on their
/// own actor without sharing the store's mutable Foundation object graph.
public struct JSONConfigStoreSnapshot: Equatable, Sendable {
    /// Canonical JSON bytes for the complete configuration root.
    public let data: Data

    /// Creates an immutable store snapshot.
    ///
    /// - Parameter data: Canonical or otherwise valid JSON object bytes.
    public init(data: Data) {
        self.data = data
    }
}
