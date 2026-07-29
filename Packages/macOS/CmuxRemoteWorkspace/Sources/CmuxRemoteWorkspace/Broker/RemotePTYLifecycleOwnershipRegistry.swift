/// Broker-queue-confined ownership index for exact PTY attachment generations.
struct RemotePTYLifecycleOwnershipRegistry {
    private struct Owner {
        let transportKey: String
        let attachmentKey: RemotePTYAttachmentKey
        let commitLease: RemotePTYLifecycleCommitLease
    }

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
        owners[lifecycleKey] = Owner(
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
        _ lifecycleKey: RemotePTYLifecycleKey
    ) -> RemotePTYLifecycleWrapperEndClaim? {
        if let owner = owners.removeValue(forKey: lifecycleKey) {
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
        guard let endedEntry = ended.take(lifecycleKey) else { return nil }
        let wasCurrent = currentByAttachmentStorage[endedEntry.attachmentKey] == nil
        return RemotePTYLifecycleWrapperEndClaim(
            transportKey: endedEntry.transportKey,
            attachmentID: endedEntry.attachmentKey.attachmentID,
            wasCurrent: wasCurrent
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
