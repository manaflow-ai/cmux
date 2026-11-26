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
        let (stream, continuation) = AsyncStream<(Bool, Bool)>.makeStream(bufferingPolicy: .unbounded)
        let token = storage.addDidChangeObserver { isBackingDefaultsNotification, canCarryActiveMutationSource in
            continuation.yield((isBackingDefaultsNotification, canCarryActiveMutationSource))
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
        #expect(secondEvent?.0 == false)
        #expect(secondEvent?.1 == true)
        #expect(thirdEvent?.0 == true)
        #expect(thirdEvent?.1 == true)
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
