import CmuxSettings
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
}
