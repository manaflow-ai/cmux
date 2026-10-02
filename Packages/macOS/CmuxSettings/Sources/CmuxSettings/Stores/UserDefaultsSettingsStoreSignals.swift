import Foundation
import os

struct UserDefaultsSettingsStoreSignal: Sendable {
    let isBackingDefaultsNotification: Bool
    let canCarryActiveMutationSource: Bool
    let logicalOrder: UInt64
    let deliveredMutationSource: UserDefaultsSettingsMutationSource?
}

final class UserDefaultsSettingsStoreSignalToken: @unchecked Sendable {
    private let id: UUID
    private let signals: UserDefaultsSettingsStoreSignals

    init(id: UUID, signals: UserDefaultsSettingsStoreSignals) {
        self.id = id
        self.signals = signals
    }

    func remove() {
        signals.removeObserver(id: id)
    }
}

final class UserDefaultsSettingsStoreSignals: @unchecked Sendable {
    private struct Observer {
        let storageKey: String
        let continuation: AsyncStream<UserDefaultsSettingsStoreSignal>.Continuation
    }

    private let observers = OSAllocatedUnfairLock(initialState: [UUID: Observer]())

    func makeStream(
        for storageKey: String,
        bufferingPolicy: AsyncStream<UserDefaultsSettingsStoreSignal>.Continuation.BufferingPolicy = .bufferingNewest(1)
    ) -> (
        stream: AsyncStream<UserDefaultsSettingsStoreSignal>,
        continuation: AsyncStream<UserDefaultsSettingsStoreSignal>.Continuation,
        token: UserDefaultsSettingsStoreSignalToken
    ) {
        let id = UUID()
        let (stream, continuation) = AsyncStream<UserDefaultsSettingsStoreSignal>.makeStream(
            bufferingPolicy: bufferingPolicy
        )
        observers.withLock { observers in
            observers[id] = Observer(storageKey: storageKey, continuation: continuation)
        }
        return (stream, continuation, UserDefaultsSettingsStoreSignalToken(id: id, signals: self))
    }

    func emit(_ signal: UserDefaultsSettingsStoreSignal, for storageKey: String) {
        let continuations = observers.withLock { observers in
            observers.values.compactMap { observer in
                observer.storageKey == storageKey ? observer.continuation : nil
            }
        }
        for continuation in continuations {
            continuation.yield(signal)
        }
    }

    fileprivate func removeObserver(id: UUID) {
        _ = observers.withLock { observers in
            observers.removeValue(forKey: id)
        }
    }
}
