public import Foundation

/// A bounded in-memory store of signed endpoint records by endpoint id.
///
/// Records arrive from the endpoint's own publish callback, from broker
/// discovery fetches, and (later) from DO push fan-out. The cache stores raw
/// signed-packet bytes; acceptance policy (signature, freshness, relay
/// allowlist) is applied by the reader at resolve time, so a policy change
/// never requires a cache flush.
public actor CmxIrohEndpointRecordCache {
    /// One cached signed record.
    public struct Entry: Equatable, Sendable {
        /// The exact signed-packet bytes.
        public let blob: Data
        /// The record's signing time, used for newest-wins replacement.
        public let signedAt: Date
        /// When this cache stored the record.
        public let storedAt: Date
    }

    /// The maximum number of endpoint ids retained.
    public static let defaultCapacity = 64

    private let capacity: Int
    private var entries: [String: Entry] = [:]
    private var insertionOrder: [String] = []

    /// Creates a cache bounded to `capacity` endpoint ids.
    public init(capacity: Int = CmxIrohEndpointRecordCache.defaultCapacity) {
        self.capacity = max(1, capacity)
    }

    /// Stores a record, keeping the newest signing time per endpoint id.
    ///
    /// - Returns: Whether the record was stored (false when an equal-or-newer
    ///   record for the same endpoint is already cached).
    @discardableResult
    public func store(
        blob: Data,
        endpointID: String,
        signedAt: Date,
        now: Date = Date()
    ) -> Bool {
        let key = endpointID.lowercased()
        if let existing = entries[key], existing.signedAt >= signedAt {
            return false
        }
        if entries[key] == nil {
            insertionOrder.append(key)
            if insertionOrder.count > capacity {
                let evicted = insertionOrder.removeFirst()
                entries[evicted] = nil
            }
        }
        entries[key] = Entry(blob: blob, signedAt: signedAt, storedAt: now)
        return true
    }

    /// Returns the cached record for an endpoint id, if any.
    public func entry(for endpointID: String) -> Entry? {
        entries[endpointID.lowercased()]
    }

    /// Removes every cached record.
    public func removeAll() {
        entries.removeAll()
        insertionOrder.removeAll()
    }
}
