import Foundation
import Testing
@preconcurrency import Sparkle
@testable import CmuxUpdater

/// The sidebar footer's update pill shows a one-word label that fits next to the account and
/// help controls. The full status stays in the pill's tooltip, its accessibility label and the
/// popover (``UpdateStateModel/text``).
@MainActor
@Suite struct UpdatePillLabelTests {
    private func pillText(_ state: UpdateState) -> String {
        let model = UpdateStateModel()
        model.setState(state)
        return model.pillText
    }

    @Test func everyPhaseHasAShortLabel() {
        let installing = UpdateState.Installing(retryTerminatingApplication: {}, dismiss: {})
        let restart = UpdateState.Installing(isAutoUpdate: true, retryTerminatingApplication: {}, dismiss: {})
        let waiting = UpdateState.Installing(
            isAutoUpdate: true,
            retryTerminatingApplication: {},
            dismiss: {},
            relaunchBlockers: UpdateRelaunchBlockers(busyAgentCount: 2, runningCommandCount: 0)
        )
        #expect(pillText(.idle) == "")
        #expect(pillText(.preparingCheck(.init(cancel: {}))) == "Checking…")
        #expect(pillText(.checking(.init(cancel: {}))) == "Checking…")
        #expect(pillText(.updateAvailable(.init(appcastItem: SUAppcastItem.empty(), reply: { _ in }))) == "Update")
        #expect(pillText(.startingDownload) == "Updating…")
        #expect(pillText(.downloading(.init(cancel: {}, expectedLength: 100, progress: 42))) == "Updating…")
        #expect(pillText(.extracting(.init(progress: 0.5))) == "Updating…")
        #expect(pillText(.installing(installing)) == "Updating…")
        #expect(pillText(.installing(restart)) == "Restart")
        #expect(pillText(.installing(waiting)) == "Update")
        #expect(pillText(.notFound(.init(acknowledgement: {}))) == "Up to Date")
        #expect(pillText(.error(.init(error: NSError(domain: "test", code: 1), retry: {}, dismiss: {}))) == "Update Failed")
    }

    @Test func labelsStayShortWhileTheFullTextStaysInTheTooltip() {
        let model = UpdateStateModel()
        model.setState(.installing(.init(isAutoUpdate: true, retryTerminatingApplication: {}, dismiss: {})))
        #expect(model.text == "Restart to Complete Update")
        #expect(model.pillText.count <= 13)
        #expect(model.pillMaxWidthText == model.pillText)
    }

    @Test func detectedBackgroundUpdateReadsUpdate() {
        let model = UpdateStateModel()
        model.debugSetDetectedVersion("0.64.26")
        #expect(model.showsDetectedBackgroundUpdate)
        #expect(model.pillText == "Update")
        #expect(model.text == "Update Available: 0.64.26")
    }
}
