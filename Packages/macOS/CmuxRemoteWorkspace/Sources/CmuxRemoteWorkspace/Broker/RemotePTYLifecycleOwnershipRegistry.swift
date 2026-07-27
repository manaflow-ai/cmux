/// Broker-queue-confined ownership index for exact PTY attachment generations.
struct RemotePTYLifecycleOwnershipRegistry {
    typealias Claim = (transportKey: String, wasCurrent: Bool)
    private typealias Owner = (transportKey: String, attachmentKey: RemotePTYAttachmentKey)
    private var owners: [RemotePTYLifecycleKey: Owner] = [:]
    private var currentByAttachmentStorage: [RemotePTYAttachmentKey: RemotePTYLifecycleKey] = [:]
    private var ended = RemotePTYEndedLifecycleRegistry()

    mutating func register(
        lifecycleKey: RemotePTYLifecycleKey,
        transportKey: String,
        attachmentKey: RemotePTYAttachmentKey
    ) {
        ended.remove(lifecycleKey)
        ended.removeAll(forAttachmentKey: attachmentKey)
        owners[lifecycleKey] = Owner(transportKey: transportKey, attachmentKey: attachmentKey)
        currentByAttachmentStorage[attachmentKey] = lifecycleKey
    }

    mutating func acknowledge(_ lifecycleKey: RemotePTYLifecycleKey) {
        ended.remove(lifecycleKey)
        guard let owner = owners.removeValue(forKey: lifecycleKey) else { return }
        if currentByAttachmentStorage[owner.attachmentKey] == lifecycleKey {
            currentByAttachmentStorage.removeValue(forKey: owner.attachmentKey)
        }
    }

    mutating func recordEnded(
        lifecycleKey: RemotePTYLifecycleKey,
        transportKey: String,
        attachmentKey: RemotePTYAttachmentKey
    ) {
        guard owners[lifecycleKey]?.transportKey == transportKey else { return }
        owners.removeValue(forKey: lifecycleKey)
        guard currentByAttachmentStorage[attachmentKey] == lifecycleKey else { return }
        currentByAttachmentStorage.removeValue(forKey: attachmentKey)
        ended.record(lifecycleKey, transportKey: transportKey, attachmentKey: attachmentKey)
    }

    mutating func claimAfterWrapperEnd(_ lifecycleKey: RemotePTYLifecycleKey) -> Claim? {
        if let owner = owners.removeValue(forKey: lifecycleKey) {
            let wasCurrent = currentByAttachmentStorage[owner.attachmentKey] == lifecycleKey
            if wasCurrent { currentByAttachmentStorage.removeValue(forKey: owner.attachmentKey) }
            ended.remove(lifecycleKey)
            return Claim(transportKey: owner.transportKey, wasCurrent: wasCurrent)
        }
        guard let endedEntry = ended.take(lifecycleKey) else { return nil }
        let wasCurrent = currentByAttachmentStorage[endedEntry.attachmentKey] == nil
        return Claim(transportKey: endedEntry.transportKey, wasCurrent: wasCurrent)
    }

    mutating func removeAll(forTransportKey transportKey: String) {
        owners = owners.filter { $0.value.transportKey != transportKey }
        currentByAttachmentStorage = currentByAttachmentStorage.filter {
            $0.key.transportKey != transportKey
        }
        ended.removeAll(forTransportKey: transportKey)
    }

    var currentByAttachment: [RemotePTYAttachmentKey: RemotePTYLifecycleKey] {
        currentByAttachmentStorage
    }
}
