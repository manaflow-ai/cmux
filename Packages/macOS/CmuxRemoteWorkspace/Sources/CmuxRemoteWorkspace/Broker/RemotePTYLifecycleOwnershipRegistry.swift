internal import os

/// Synchronous ownership index for exact PTY attachment generations.
///
/// `@unchecked Sendable` is safe because `state` guards every read and mutation.
final class RemotePTYLifecycleOwnershipRegistry: @unchecked Sendable {
    typealias Claim = (transportKey: String, wasCurrent: Bool)
    private typealias Owner = (transportKey: String, attachmentKey: RemotePTYAttachmentKey)
    private typealias State = (
        owners: [RemotePTYLifecycleKey: Owner],
        currentByAttachment: [RemotePTYAttachmentKey: RemotePTYLifecycleKey],
        ended: RemotePTYEndedLifecycleRegistry
    )

    // Lock carve-out: wrapper-end RPC handling needs an immediate exact-generation
    // compare-and-set on the main actor. The broker queue also performs blocking PTY
    // RPCs, while this lock guards only bounded in-memory index operations.
    private let state = OSAllocatedUnfairLock(initialState: State(
        owners: [:],
        currentByAttachment: [:],
        ended: RemotePTYEndedLifecycleRegistry()
    ))

    func register(
        lifecycleKey: RemotePTYLifecycleKey,
        transportKey: String,
        attachmentKey: RemotePTYAttachmentKey
    ) {
        state.withLock { state in
            state.ended.remove(lifecycleKey)
            state.ended.removeAll(forAttachmentKey: attachmentKey)
            state.owners[lifecycleKey] = Owner(
                transportKey: transportKey,
                attachmentKey: attachmentKey
            )
            state.currentByAttachment[attachmentKey] = lifecycleKey
        }
    }

    func acknowledge(_ lifecycleKey: RemotePTYLifecycleKey) {
        state.withLock { state in
            state.ended.remove(lifecycleKey)
            guard let owner = state.owners.removeValue(forKey: lifecycleKey) else { return }
            if state.currentByAttachment[owner.attachmentKey] == lifecycleKey {
                state.currentByAttachment.removeValue(forKey: owner.attachmentKey)
            }
        }
    }

    func recordEnded(
        lifecycleKey: RemotePTYLifecycleKey,
        transportKey: String,
        attachmentKey: RemotePTYAttachmentKey
    ) {
        state.withLock { state in
            guard state.owners[lifecycleKey]?.transportKey == transportKey else { return }
            state.owners.removeValue(forKey: lifecycleKey)
            guard state.currentByAttachment[attachmentKey] == lifecycleKey else { return }
            state.currentByAttachment.removeValue(forKey: attachmentKey)
            state.ended.record(
                lifecycleKey,
                transportKey: transportKey,
                attachmentKey: attachmentKey
            )
        }
    }

    func claimAfterWrapperEnd(_ lifecycleKey: RemotePTYLifecycleKey) -> Claim? {
        state.withLock { state in
            if let owner = state.owners.removeValue(forKey: lifecycleKey) {
                let wasCurrent = state.currentByAttachment[owner.attachmentKey] == lifecycleKey
                if wasCurrent { state.currentByAttachment.removeValue(forKey: owner.attachmentKey) }
                state.ended.remove(lifecycleKey)
                return Claim(transportKey: owner.transportKey, wasCurrent: wasCurrent)
            }
            guard let ended = state.ended.take(lifecycleKey) else { return nil }
            let wasCurrent = state.currentByAttachment[ended.attachmentKey] == nil
            return Claim(transportKey: ended.transportKey, wasCurrent: wasCurrent)
        }
    }

    func removeAll(forTransportKey transportKey: String) {
        state.withLock { state in
            state.owners = state.owners.filter { $0.value.transportKey != transportKey }
            state.currentByAttachment = state.currentByAttachment.filter {
                $0.key.transportKey != transportKey
            }
            state.ended.removeAll(forTransportKey: transportKey)
        }
    }

    var currentByAttachment: [RemotePTYAttachmentKey: RemotePTYLifecycleKey] {
        state.withLock { $0.currentByAttachment }
    }
}
