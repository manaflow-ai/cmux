/// Bounded, broker-queue-confined state for a lifecycle that ended before its wrapper RPC arrived.
struct RemotePTYEndedLifecycleRegistry {
    typealias Entry = (transportKey: String, attachmentKey: RemotePTYAttachmentKey)

    /// Caps delayed-wrapper reconciliation without retaining every surface on a shared transport.
    static let capacity = 256

    private var entries: [RemotePTYLifecycleKey: Entry] = [:]
    private var insertionOrder: [RemotePTYLifecycleKey] = []

    var count: Int { entries.count }

    mutating func record(
        _ lifecycleKey: RemotePTYLifecycleKey,
        transportKey: String,
        attachmentKey: RemotePTYAttachmentKey
    ) {
        let supersededKeys = entries.compactMap { key, entry in
            entry.attachmentKey == attachmentKey && key != lifecycleKey ? key : nil
        }
        for supersededKey in supersededKeys { remove(supersededKey) }
        let entry = Entry(transportKey: transportKey, attachmentKey: attachmentKey)
        if entries.updateValue(entry, forKey: lifecycleKey) == nil {
            insertionOrder.append(lifecycleKey)
        }
        while insertionOrder.count > Self.capacity {
            entries.removeValue(forKey: insertionOrder.removeFirst())
        }
    }

    mutating func take(_ lifecycleKey: RemotePTYLifecycleKey) -> Entry? {
        guard let entry = entries.removeValue(forKey: lifecycleKey) else { return nil }
        insertionOrder.removeAll { $0 == lifecycleKey }
        return entry
    }

    mutating func remove(_ lifecycleKey: RemotePTYLifecycleKey) {
        guard entries.removeValue(forKey: lifecycleKey) != nil else { return }
        insertionOrder.removeAll { $0 == lifecycleKey }
    }

    mutating func removeAll(forAttachmentKey attachmentKey: RemotePTYAttachmentKey) {
        let matchingKeys = entries.compactMap { key, entry in
            entry.attachmentKey == attachmentKey ? key : nil
        }
        for matchingKey in matchingKeys { remove(matchingKey) }
    }

    mutating func removeAll(forTransportKey transportKey: String) {
        entries = entries.filter { $0.value.transportKey != transportKey }
        insertionOrder.removeAll { entries[$0] == nil }
    }
}
