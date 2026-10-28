import CmuxNextOnboarding
import CmuxNextAgentPermissions
@testable import CmuxNextApp
import CmuxNextWakeups
import Foundation
import Testing

@MainActor struct ComputerUsePermissionRequestTests {
    @Test(arguments: [PermissionKind.accessibility, .screenRecording, .computerUse])
    func agentContinueRequestsOnlyTheCurrentGrant(_ kind: PermissionKind) {
        var requested: [ComputerUsePermissionPane] = []
        var opened: [URL] = []
        var enabled = 0
        let rig = MainDeadlineRig()
        let setup = ComputerUseSetup(
            inputs: { .init(disabledByPolicy: false, enabled: false, helper: .off) },
            configuration: { nil },
            resolveHelper: { _ in nil },
            openURL: { opened.append($0) },
            requestPermission: { requested.append($0) },
            enableSetting: { enabled += 1 },
            appEvents: AppEvents(center: NotificationCenter()), distributedEvents: AppEvents(center: NotificationCenter()),
            deadlines: rig.deadlines, work: BackgroundWork()
        )
        let opener = SystemPermissionOpener(setup: setup, work: BackgroundWork())
        #expect(requested.isEmpty)
        opener.open(kind, target: nil)
        let pane: ComputerUsePermissionPane = kind == .screenRecording ? .screenRecording : .accessibility
        #expect(enabled == 1)
        #expect(requested == [pane])
        #expect(opened.count == 1)
        #expect(opened.first == ComputerUseSetup.settingsURL(pane))
    }

    @Test func launchAndStatusNeverRequestGrantsButSetupRequestsOnlyTheClickedGrant() {
        var requested: [ComputerUsePermissionPane] = []
        var opened: [URL] = []
        let rig = MainDeadlineRig()
        let setup = ComputerUseSetup(
            inputs: { .init(disabledByPolicy: false, enabled: true, helper: .off) },
            configuration: { nil },
            resolveHelper: { _ in nil },
            openURL: { opened.append($0) },
            requestPermission: { requested.append($0) },
            appEvents: AppEvents(center: NotificationCenter()), distributedEvents: AppEvents(center: NotificationCenter()),
            deadlines: rig.deadlines, work: BackgroundWork()
        )
        setup.start()
        setup.recheck()
        _ = setup.pageJSON
        #expect(requested.isEmpty)
        #expect(opened.isEmpty)

        setup.open(.accessibility)
        #expect(requested == [.accessibility])
        #expect(opened.last?.absoluteString.hasSuffix("Privacy_Accessibility") == true)

        setup.open(.screenRecording)
        #expect(requested == [.accessibility, .screenRecording])
        #expect(opened.last?.absoluteString.hasSuffix("Privacy_ScreenCapture") == true)
    }
}
