import SwiftUI
import Testing
@testable import CmuxUpdater
@testable import CmuxUpdaterUI

@MainActor
@Suite struct UpdateAppearanceTests {
    @Test func accentIsStored() {
        #expect(UpdateAppearance(accent: .red).accent == .red)
    }

    @Test func idleUsesNeutralColors() {
        let model = UpdateStateModel()
        let appearance = UpdateAppearance(accent: .red)
        #expect(appearance.foregroundColor(for: model) == .primary)
        #expect(appearance.iconColor(for: model) == .secondary)
    }

    @Test func notFoundUsesWhiteForeground() {
        let model = UpdateStateModel()
        model.setState(.notFound(.init(acknowledgement: {})))
        let appearance = UpdateAppearance(accent: .red)
        #expect(appearance.foregroundColor(for: model) == .white)
    }
}
