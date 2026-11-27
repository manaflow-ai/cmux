internal import Foundation

/// Process-local async fanout for disruptive shared-ControlMaster reaps.
actor NativeSSHControlMasterReapEventHub {
    private var observers: [
        String: [UUID: AsyncStream<UUID>.Continuation]
    ] = [:]

    func events(controlPath: String) -> AsyncStream<UUID> {
        let observerID = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) {
            continuation in
            observers[controlPath, default: [:]][observerID] = continuation
            continuation.onTermination = { [weak self] _ in
                Task {
                    await self?.removeObserver(
                        observerID,
                        controlPath: controlPath
                    )
                }
            }
        }
    }

    func emit(controlPath: String) -> UUID {
        let eventID = UUID()
        guard let continuations = observers[controlPath]?.values else {
            return eventID
        }
        for continuation in continuations {
            continuation.yield(eventID)
        }
        return eventID
    }

    private func removeObserver(
        _ observerID: UUID,
        controlPath: String
    ) {
        observers[controlPath]?.removeValue(forKey: observerID)
        if observers[controlPath]?.isEmpty == true {
            observers.removeValue(forKey: controlPath)
        }
    }
}
