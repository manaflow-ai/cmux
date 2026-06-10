import Foundation
import Testing
@testable import CmuxUpdater

@MainActor
@Suite struct UpdateStateModelTests {
    @Test func setStateEmitsOnStateChangesStream() async {
        let model = UpdateStateModel()
        var iterator = model.stateChanges().makeAsyncIterator()

        model.setState(.checking(.init(cancel: {})))
        let signal: Void? = await iterator.next()

        #expect(signal != nil)
        #expect(model.state == .checking(.init(cancel: {})))
    }

    @Test func setOverrideStateAlsoEmits() async {
        let model = UpdateStateModel()
        var iterator = model.stateChanges().makeAsyncIterator()

        model.setOverrideState(.notFound(.init(acknowledgement: {})))
        let signal: Void? = await iterator.next()

        #expect(signal != nil)
        #expect(model.overrideState == .notFound(.init(acknowledgement: {})))
    }

    @Test func effectiveStatePrefersOverride() {
        let model = UpdateStateModel()
        model.setState(.idle)
        model.setOverrideState(.checking(.init(cancel: {})))
        #expect(model.effectiveState == .checking(.init(cancel: {})))
        #expect(model.showsPill)
    }

    @Test func idleWithNoDetectedUpdateHidesPill() {
        let model = UpdateStateModel()
        #expect(model.state == .idle)
        #expect(!model.showsPill)
        #expect(model.iconName == nil)
        #expect(model.text.isEmpty)
    }

    @Test func notFoundProducesTitleAndIcon() {
        let model = UpdateStateModel()
        model.setState(.notFound(.init(acknowledgement: {})))
        #expect(model.iconName == "info.circle")
        #expect(!model.text.isEmpty)
    }

    @Test func networkErrorTitleIsUserFacing() {
        let offline = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)
        let title = UpdateStateModel.userFacingErrorTitle(for: offline)
        #expect(title == "No Internet Connection")
    }

    @Test func errorDetailsIncludesLogPath() {
        let err = NSError(domain: "cmux.update", code: 7, userInfo: [NSLocalizedDescriptionKey: "boom"])
        let details = UpdateStateModel.errorDetails(for: err, technicalDetails: "ctx", feedURLString: "https://feed", logPath: "/tmp/x.log")
        #expect(details.contains("Log: /tmp/x.log"))
        #expect(details.contains("Feed: https://feed"))
        #expect(details.contains("Debug: ctx"))
    }

    @Test func normalizedVersionTrimsAndRejectsEmpty() {
        #expect(UpdateStateModel.normalizedDetectedUpdateVersion(from: "  1.2.3 ") == "1.2.3")
        #expect(UpdateStateModel.normalizedDetectedUpdateVersion(from: "   ") == nil)
    }

    // MARK: - Installer / launchd-agent failure (SUInstallationError 4005, SUAgentInvalidationError 4010)
    //
    // Domain literal "SUSparkleErrorDomain" matches the value of Sparkle's `SUSparkleErrorDomain`
    // constant, so tests don't need to import Sparkle. Title/message assertions check English
    // substrings because `String(localized:)` falls back to its `defaultValue` under the test bundle.

    /// Regression: a 4005 installation error wrapping an agent-connection timeout (the wedged
    /// launchd-session case) must steer the user to restart, not the misleading "move into
    /// Applications" guidance that the old code returned for every 4005.
    @Test func installerAgentFailureTellsUserToRestartNotRelocate() {
        let underlying = NSError(
            domain: "SUSparkleErrorDomain",
            code: 10,
            userInfo: [NSLocalizedDescriptionKey: "Timeout: agent connection was never initiated"]
        )
        let err = NSError(
            domain: "SUSparkleErrorDomain",
            code: 4005,
            userInfo: [
                NSLocalizedDescriptionKey: "An error occurred while running the updater.",
                NSUnderlyingErrorKey: underlying,
            ]
        )
        let message = UpdateStateModel.userFacingErrorMessage(for: err)
        #expect(message.localizedCaseInsensitiveContains("restart"))
        #expect(!message.localizedCaseInsensitiveContains("Applications"))
    }

}
