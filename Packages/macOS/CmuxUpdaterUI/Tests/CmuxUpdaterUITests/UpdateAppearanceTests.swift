import AppKit
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

    @Test func notFoundBackgroundIsADarkerShadeOfTheAccent() throws {
        let model = UpdateStateModel()
        model.setState(.notFound(.init(acknowledgement: {})))
        let appearance = UpdateAppearance(accent: Color(nsColor: NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)))
        let background = try #require(NSColor(appearance.backgroundColor(for: model)).usingColorSpace(.sRGB))
        #expect(abs(background.redComponent - 0.5) < 0.01)
        #expect(background.greenComponent < 0.01)
        #expect(background.blueComponent < 0.01)
    }
}
