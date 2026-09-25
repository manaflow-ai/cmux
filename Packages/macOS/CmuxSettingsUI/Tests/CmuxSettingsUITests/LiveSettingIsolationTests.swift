import CmuxSettings
import os
import SwiftUI
import Testing

@testable import CmuxSettingsUI

@Suite struct LiveSettingIsolationTests {
    @MainActor
    @Test func dynamicPropertyWitnessRunsWithoutMainActorExecutor() async {
        // The lock exclusively owns the non-Sendable property after construction;
        // every detached access occurs synchronously under that same lock.
        let box = OSAllocatedUnfairLock(
            uncheckedState: (LiveSetting(\.betaFeatures.extensions) as any DynamicProperty)
        )
        let didUpdate = await Task.detached {
            box.withLock { $0.update() }
            return true
        }.value

        #expect(didUpdate)
    }

    @Test func readDriverActivatesExactlyOnceAcrossConcurrentUpdates() async {
        let driver = SettingReadDriver<Int>()
        let activationCount = OSAllocatedUnfairLock(initialState: 0)

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<64 {
                group.addTask {
                    driver.activate({
                        activationCount.withLock { $0 += 1 }
                        return AsyncStream { $0.finish() }
                    }) { _ in }
                }
            }
        }

        #expect(activationCount.withLock { $0 } == 1)
    }

    @Test func asyncReadDriverActivatesExactlyOnceAcrossConcurrentUpdates() async {
        let driver = SettingReadDriver<Int>()
        let activationCount = OSAllocatedUnfairLock(initialState: 0)
        let (activations, activationContinuation) = AsyncStream<Void>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<64 {
                group.addTask {
                    driver.activateAsync({
                        activationCount.withLock { $0 += 1 }
                        activationContinuation.yield()
                        return AsyncStream { $0.finish() }
                    }) { _ in }
                }
            }
        }

        var activationIterator = activations.makeAsyncIterator()
        let didActivate = await activationIterator.next() != nil
        activationContinuation.finish()

        #expect(didActivate)
        #expect(activationCount.withLock { $0 } == 1)
    }
}
