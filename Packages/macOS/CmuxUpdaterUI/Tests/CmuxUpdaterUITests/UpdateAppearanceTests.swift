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

    @Test func preparedUpdatePillRestartsImmediately() {
        let model = UpdateStateModel()
        let actions = UpdateActionsHostSpy()
        var restartCount = 0
        model.setState(.installing(.init(
            retryTerminatingApplication: { restartCount += 1 },
            dismiss: {}
        )))

        UpdatePill(model: model, accent: .red, actions: actions).handleTap()

        #expect(restartCount == 1)
        #expect(actions.attemptUpdateCount == 0)
        #expect(actions.customCheckCount == 0)
    }
}

@MainActor
private final class UpdateActionsHostSpy: UpdateActionsHost {
    var customCheckCount = 0
    var attemptUpdateCount = 0
    let updateLogPath = "/tmp/update.log"

    func checkForUpdatesInCustomUI() {
        customCheckCount += 1
    }

    func attemptUpdate() {
        attemptUpdateCount += 1
    }
}
