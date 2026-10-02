/// Broker-queue-confined ownership index for exact PTY attachment generations.
struct RemotePTYLifecycleOwnershipRegistry {
    private typealias Owner = (
        transportKey: String,
        attachmentKey: RemotePTYAttachmentKey,
        commitLease: RemotePTYLifecycleCommitLease
    )
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
        if let replacedOwner = owners[lifecycleKey] {
            replacedOwner.commitLease.invalidate()
        }
        if let displacedLifecycleKey = currentByAttachmentStorage[attachmentKey],
           let displacedOwner = owners[displacedLifecycleKey] {
            displacedOwner.commitLease.invalidate()
        }
        owners[lifecycleKey] = (
            transportKey: transportKey,
            attachmentKey: attachmentKey,
            commitLease: RemotePTYLifecycleCommitLease()
        )
        currentByAttachmentStorage[attachmentKey] = lifecycleKey
    }

    mutating func acknowledge(_ lifecycleKey: RemotePTYLifecycleKey) {
        ended.remove(lifecycleKey)
        guard let owner = owners.removeValue(forKey: lifecycleKey) else { return }
        owner.commitLease.invalidate()
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
        let owner = owners.removeValue(forKey: lifecycleKey)
        owner?.commitLease.invalidate()
        guard currentByAttachmentStorage[attachmentKey] == lifecycleKey else { return }
        currentByAttachmentStorage.removeValue(forKey: attachmentKey)
        ended.record(lifecycleKey, transportKey: transportKey, attachmentKey: attachmentKey)
    }

    mutating func claimAfterWrapperEnd(
        _ lifecycleKey: RemotePTYLifecycleKey,
        expectedOwner: RemotePTYLifecycleWrapperEndOwner? = nil
    ) -> RemotePTYLifecycleWrapperEndClaim? {
        if let owner = owners[lifecycleKey] {
            guard expectedOwner == nil || expectedOwner == RemotePTYLifecycleWrapperEndOwner(
                transportKey: owner.transportKey,
                attachmentID: owner.attachmentKey.attachmentID
            ) else {
                return nil
            }
            owners.removeValue(forKey: lifecycleKey)
            owner.commitLease.invalidate()
            let wasCurrent = currentByAttachmentStorage[owner.attachmentKey] == lifecycleKey
            if wasCurrent { currentByAttachmentStorage.removeValue(forKey: owner.attachmentKey) }
            ended.remove(lifecycleKey)
            return RemotePTYLifecycleWrapperEndClaim(
                transportKey: owner.transportKey,
                attachmentID: owner.attachmentKey.attachmentID,
                wasCurrent: wasCurrent
            )
        }
        guard let endedEntry = ended.entry(for: lifecycleKey),
              expectedOwner == nil || expectedOwner == RemotePTYLifecycleWrapperEndOwner(
                  transportKey: endedEntry.transportKey,
                  attachmentID: endedEntry.attachmentKey.attachmentID
              ) else {
            return nil
        }
        ended.remove(lifecycleKey)
        let wasCurrent = currentByAttachmentStorage[endedEntry.attachmentKey] == nil
        return RemotePTYLifecycleWrapperEndClaim(
            transportKey: endedEntry.transportKey,
            attachmentID: endedEntry.attachmentKey.attachmentID,
            wasCurrent: wasCurrent
        )
    }

    func ownerForWrapperEnd(
        _ lifecycleKey: RemotePTYLifecycleKey
    ) -> RemotePTYLifecycleWrapperEndOwner? {
        if let owner = owners[lifecycleKey] {
            return RemotePTYLifecycleWrapperEndOwner(
                transportKey: owner.transportKey,
                attachmentID: owner.attachmentKey.attachmentID
            )
        }
        guard let endedEntry = ended.entry(for: lifecycleKey) else { return nil }
        return RemotePTYLifecycleWrapperEndOwner(
            transportKey: endedEntry.transportKey,
            attachmentID: endedEntry.attachmentKey.attachmentID
        )
    }

    func currentOwner(
        _ lifecycleKey: RemotePTYLifecycleKey
    ) -> RemotePTYLifecycleOwner? {
        guard let owner = owners[lifecycleKey],
              currentByAttachmentStorage[owner.attachmentKey] == lifecycleKey else {
            return nil
        }
        return RemotePTYLifecycleOwner(
            transportKey: owner.transportKey,
            attachmentID: owner.attachmentKey.attachmentID,
            commitLease: owner.commitLease
        )
    }

    mutating func removeAll(forTransportKey transportKey: String) {
        for owner in owners.values where owner.transportKey == transportKey {
            owner.commitLease.invalidate()
        }
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
