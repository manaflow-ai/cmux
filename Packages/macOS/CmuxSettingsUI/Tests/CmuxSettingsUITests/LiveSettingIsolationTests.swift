import CmuxSettings
import os
import SwiftUI
import Testing

@testable import CmuxSettingsUI

/// Transfers a dynamic property to exactly one detached task after construction;
/// no other task accesses the boxed value, so the unchecked transfer is exclusive.
private final class ExclusiveDynamicPropertyBox<Property: DynamicProperty>: @unchecked Sendable {
    private var property: Property

    init(_ property: Property) {
        self.property = property
    }

    func update() {
        property.update()
    }
}

@Suite struct LiveSettingIsolationTests {
    @MainActor
    @Test func dynamicPropertyWitnessRunsWithoutMainActorExecutor() async {
        let box = ExclusiveDynamicPropertyBox(
            LiveSetting(\.betaFeatures.extensions)
        )
        let didUpdate = await Task.detached {
            box.update()
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
}
