import CmuxSettings
import os
import Testing

@testable import CmuxSettingsUI

@Suite struct SettingReadDriverIsolationTests {
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
