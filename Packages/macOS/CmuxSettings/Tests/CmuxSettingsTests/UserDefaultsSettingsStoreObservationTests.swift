import Foundation
import Testing

@testable import CmuxSettings

@Suite("UserDefaultsSettingsStore observation")
struct UserDefaultsSettingsStoreObservationTests {
    @Test func changeSignalsDoNotWaitForMainActorObservers() async {
        let notificationCenter = NotificationCenter()
        let stream = UserDefaultsSettingsStore.changeSignals(
            notificationCenter: notificationCenter
        )
        var iterator = stream.makeAsyncIterator()

        // Deliberately hold the main actor to model the XCTest/session
        // initialization cycle from #12532. These semaphores are signals, not
        // locks: the test releases the actor before teardown.
        let mainEntered = DispatchSemaphore(value: 0)
        let releaseMain = DispatchSemaphore(value: 0)
        let blocker = Task { @MainActor in
            mainEntered.signal()
            _ = waitForSignal(releaseMain, timeout: .distantFuture)
        }
        guard waitForSignal(mainEntered, timeout: .now() + 5) == .success else {
            releaseMain.signal()
            blocker.cancel()
            Issue.record("MainActor blocker did not start")
            return
        }
        defer {
            releaseMain.signal()
            blocker.cancel()
        }

        let postFinished = DispatchSemaphore(value: 0)
        let postingFinishedSignal = postFinished
        let postingCenter = notificationCenter
        Task.detached {
            postingCenter.post(
                name: UserDefaults.didChangeNotification,
                object: nil
            )
            postingFinishedSignal.signal()
        }

        // This is a liveness watchdog for the known UserDefaults/main-queue
        // deadlock, not a performance assertion. Five seconds leaves ample
        // room for a loaded CI host while still bounding the pre-fix hang.
        #expect(waitForSignal(postFinished, timeout: .now() + 5) == .success)
        releaseMain.signal()
        _ = waitForSignal(postFinished, timeout: .now() + 5)
        #expect(await iterator.next() != nil)
    }

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

private func waitForSignal(
    _ semaphore: DispatchSemaphore,
    timeout: DispatchTime
) -> DispatchTimeoutResult {
    semaphore.wait(timeout: timeout)
}
