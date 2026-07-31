import Foundation
import Testing

@testable import CmuxSettings

@Suite("UserDefaultsSettingsStore observation")
struct UserDefaultsSettingsStoreObservationTests {
    @Test func storageChangeObserverClassifiesDefaultsNotifications() async {
        let observedDefaults = UserDefaults(suiteName: "cmux.tests.\(UUID().uuidString)")!
        let otherDefaults = UserDefaults(suiteName: "cmux.tests.\(UUID().uuidString)")!
        let notificationCenter = NotificationCenter()
        let storage = UserDefaultsSettingsStorage(
            defaults: observedDefaults,
            notificationCenter: notificationCenter
        )
        let (stream, continuation) = AsyncStream<(Bool, Bool, Bool)>.makeStream(bufferingPolicy: .unbounded)
        let token = storage.addDidChangeObserver {
            isBackingDefaultsNotification,
            canCarryActiveMutationSource,
            isInheritedDefaultNotification in
            continuation.yield((
                isBackingDefaultsNotification,
                canCarryActiveMutationSource,
                isInheritedDefaultNotification
            ))
        }
        defer {
            token.remove()
            continuation.finish()
        }

        notificationCenter.post(name: UserDefaults.didChangeNotification, object: otherDefaults)
        notificationCenter.post(name: UserDefaults.didChangeNotification, object: nil)
        notificationCenter.post(name: UserDefaults.didChangeNotification, object: observedDefaults)

        var iterator = stream.makeAsyncIterator()
        let firstEvent = await iterator.next()
        let secondEvent = await iterator.next()
        let thirdEvent = await iterator.next()
        #expect(firstEvent?.0 == false)
        #expect(firstEvent?.1 == false)
        #expect(firstEvent?.2 == false)
        #expect(secondEvent?.0 == false)
        #expect(secondEvent?.1 == true)
        #expect(secondEvent?.2 == false)
        #expect(thirdEvent?.0 == true)
        #expect(thirdEvent?.1 == true)
        #expect(thirdEvent?.2 == false)
    }

    @Test func storageChangeObserverClassifiesRemoteCacheMutationAsInherited() async {
        let observedDefaults = UserDefaults(suiteName: "cmux.tests.\(UUID().uuidString)")!
        let notificationCenter = NotificationCenter()
        let storage = UserDefaultsSettingsStorage(
            defaults: observedDefaults,
            notificationCenter: notificationCenter
        )
        let (stream, continuation) = AsyncStream<(Bool, Bool, Bool)>.makeStream(
            bufferingPolicy: .unbounded
        )
        let storageKey = "tests.beta.enabled"
        let token = storage.addDidChangeObserver(for: storageKey) {
            isBackingDefaultsNotification,
            canCarryActiveMutationSource,
            isInheritedDefaultNotification in
            continuation.yield((
                isBackingDefaultsNotification,
                canCarryActiveMutationSource,
                isInheritedDefaultNotification
            ))
        }
        defer {
            token.remove()
            continuation.finish()
        }

        let userInfo = [
            CmuxSettingsRemoteDefaultNotification.storageKeyUserInfoKey: storageKey,
        ]
        notificationCenter.post(
            name: .cmuxSettingsRemoteDefaultWillChange,
            object: observedDefaults,
            userInfo: userInfo
        )
        notificationCenter.post(
            name: UserDefaults.didChangeNotification,
            object: observedDefaults
        )
        notificationCenter.post(
            name: .cmuxSettingsRemoteDefaultDidChange,
            object: observedDefaults,
            userInfo: userInfo
        )

        var iterator = stream.makeAsyncIterator()
        let broadEvent = await iterator.next()
        let targetedEvent = await iterator.next()
        #expect(broadEvent?.0 == true)
        #expect(broadEvent?.1 == false)
        #expect(broadEvent?.2 == true)
        #expect(targetedEvent?.0 == true)
        #expect(targetedEvent?.1 == false)
        #expect(targetedEvent?.2 == true)
    }

    @Test func remoteNotificationDepthPairsOnlyForObservedStorageKey() {
        let suiteName = "cmux.tests.\(UUID().uuidString)"
        let observedDefaults = UserDefaults(suiteName: suiteName)!
        observedDefaults.removePersistentDomain(forName: suiteName)
        defer { observedDefaults.removePersistentDomain(forName: suiteName) }
        let notificationCenter = NotificationCenter()
        let storage = UserDefaultsSettingsStorage(
            defaults: observedDefaults,
            notificationCenter: notificationCenter
        )
        let recorder = NotificationClassificationRecorder()
        let observedKey = "tests.beta.observed"
        let token = storage.addDidChangeObserver(for: observedKey) {
            isBackingDefaultsNotification,
            canCarryActiveMutationSource,
            isInheritedDefaultNotification in
            recorder.append(NotificationClassification(
                isBackingDefaultsNotification: isBackingDefaultsNotification,
                canCarryActiveMutationSource: canCarryActiveMutationSource,
                isInheritedDefaultNotification: isInheritedDefaultNotification
            ))
        }
        defer { token.remove() }

        func postRemote(_ name: Notification.Name, storageKey: String) {
            notificationCenter.post(
                name: name,
                object: observedDefaults,
                userInfo: [
                    CmuxSettingsRemoteDefaultNotification.storageKeyUserInfoKey: storageKey,
                ]
            )
        }

        postRemote(.cmuxSettingsRemoteDefaultWillChange, storageKey: "tests.beta.other")
        notificationCenter.post(name: UserDefaults.didChangeNotification, object: observedDefaults)

        postRemote(.cmuxSettingsRemoteDefaultWillChange, storageKey: observedKey)
        notificationCenter.post(name: UserDefaults.didChangeNotification, object: observedDefaults)
        postRemote(.cmuxSettingsRemoteDefaultDidChange, storageKey: "tests.beta.other")
        notificationCenter.post(name: UserDefaults.didChangeNotification, object: observedDefaults)
        postRemote(.cmuxSettingsRemoteDefaultDidChange, storageKey: observedKey)
        notificationCenter.post(name: UserDefaults.didChangeNotification, object: observedDefaults)

        #expect(recorder.snapshot() == [
            NotificationClassification(true, true, false),
            NotificationClassification(true, false, true),
            NotificationClassification(true, false, true),
            NotificationClassification(true, false, true),
            NotificationClassification(true, true, false),
        ])
    }

    @Test func valueEventBufferCarriesDroppedSourcesOntoSourceTaggedSurvivor() async {
        let firstSource = UserDefaultsSettingsMutationSource()
        let secondSource = UserDefaultsSettingsMutationSource()
        let thirdSource = UserDefaultsSettingsMutationSource()
        let (stream, continuation) = AsyncStream<UserDefaultsSettingsValueEvent<String>>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )

        continuation.yieldPreservingSources(
            UserDefaultsSettingsValueEvent(value: "#111111", mutationSource: firstSource)
        )
        continuation.yieldPreservingSources(
            UserDefaultsSettingsValueEvent(value: "#222222", mutationSource: secondSource)
        )
        continuation.yieldPreservingSources(
            UserDefaultsSettingsValueEvent(value: "#333333", mutationSource: thirdSource)
        )

        var iterator = stream.makeAsyncIterator()
        let event = await iterator.next()
        #expect(event?.value == "#333333")
        #expect(event?.mutationSource == thirdSource)
        #expect(event?.supersededMutationSources.contains(firstSource) == true)
        #expect(event?.supersededMutationSources.contains(secondSource) == true)
    }
}

private struct NotificationClassification: Sendable, Equatable {
    let isBackingDefaultsNotification: Bool
    let canCarryActiveMutationSource: Bool
    let isInheritedDefaultNotification: Bool

    init(
        _ isBackingDefaultsNotification: Bool,
        _ canCarryActiveMutationSource: Bool,
        _ isInheritedDefaultNotification: Bool
    ) {
        self.init(
            isBackingDefaultsNotification: isBackingDefaultsNotification,
            canCarryActiveMutationSource: canCarryActiveMutationSource,
            isInheritedDefaultNotification: isInheritedDefaultNotification
        )
    }

    init(
        isBackingDefaultsNotification: Bool,
        canCarryActiveMutationSource: Bool,
        isInheritedDefaultNotification: Bool
    ) {
        self.isBackingDefaultsNotification = isBackingDefaultsNotification
        self.canCarryActiveMutationSource = canCarryActiveMutationSource
        self.isInheritedDefaultNotification = isInheritedDefaultNotification
    }
}

private final class NotificationClassificationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [NotificationClassification] = []

    func append(_ value: NotificationClassification) {
        lock.withLock {
            values.append(value)
        }
    }

    func snapshot() -> [NotificationClassification] {
        lock.withLock { values }
    }
}
