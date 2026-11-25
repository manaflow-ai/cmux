import CmuxNextOnboarding
import CmuxNextAgentPermissions
@testable import CmuxNextApp
import Foundation
import Testing

@MainActor struct ComputerUsePermissionRequestTests {
    /// Continue on the agent card shows the Computer Use window; the grant is requested only when the
    /// person clicks Allow there (`ComputerUseSetup.open`), for that grant alone.
    @Test(arguments: [PermissionKind.accessibility, .screenRecording, .computerUse])
    func agentContinueShowsTheWindowAndAllowRequestsOnlyThatGrant(_ kind: PermissionKind) {
        var requested: [ComputerUsePermissionPane] = []
        var opened: [URL] = []
        var enabled = 0
        var shown = 0
        let setup = ComputerUseSetup(
            inputs: { .init(disabledByPolicy: false, enabled: false, helper: .off) },
            configuration: { nil },
            openURL: { opened.append($0) },
            requestPermission: { requested.append($0) },
            enableSetting: { enabled += 1 }
        )
        let opener = SystemPermissionOpener(setup: setup, showComputerUse: { shown += 1 }, openURL: { opened.append($0) })
        opener.open(kind, target: nil)
        #expect(enabled == 1)
        #expect(shown == 1)
        #expect(requested.isEmpty)
        #expect(opened.isEmpty)

        let pane: ComputerUsePermissionPane = kind == .screenRecording ? .screenRecording : .accessibility
        setup.open(pane)
        #expect(requested == [pane])
        #expect(opened == [ComputerUseSetup.settingsURL(pane)].compactMap { $0 })
    }

    /// The window reads the legacy helper's grants only: under the helper v2, Continue asks for the
    /// card's grant directly and opens its list, with no window.
    @Test(arguments: [PermissionKind.accessibility, .screenRecording, .computerUse])
    func upstreamContinueRequestsTheGrantWithoutTheWindow(_ kind: PermissionKind) {
        var requested: [ComputerUsePermissionPane] = []
        var opened: [URL] = []
        var shown = 0
        let setup = ComputerUseSetup(
            inputs: { .init(disabledByPolicy: false, enabled: true, helper: .off, driver: .upstream) },
            configuration: { nil },
            resolveHelper: { _ in nil },
            openURL: { opened.append($0) },
            requestPermission: { requested.append($0) }
        )
        setup.start()
        let opener = SystemPermissionOpener(setup: setup, showComputerUse: { shown += 1 }, openURL: { opened.append($0) })
        opener.open(kind, target: nil)
        let pane: ComputerUsePermissionPane = kind == .screenRecording ? .screenRecording : .accessibility
        #expect(shown == 0)
        #expect(requested == [pane])
        #expect(opened == [ComputerUseSetup.settingsURL(pane)].compactMap { $0 })
    }

    /// The card hides after Continue only when the Computer Use window took over: under the
    /// upstream driver no window opens, so the card must keep guiding the grant.
    @Test func theCardStepsAsideOnlyWhenTheWindowGuides() {
        for kind in [PermissionKind.accessibility, .screenRecording, .computerUse] {
            #expect(SystemPermissionOpener.guidesInWindow(kind, driver: .legacy))
            #expect(!SystemPermissionOpener.guidesInWindow(kind, driver: .upstream))
        }
        #expect(!SystemPermissionOpener.guidesInWindow(.fullDiskAccess, driver: .legacy))
    }

    @Test func launchAndStatusNeverRequestGrantsButSetupRequestsOnlyTheClickedGrant() {
        var requested: [ComputerUsePermissionPane] = []
        var opened: [URL] = []
        let setup = ComputerUseSetup(
            inputs: { .init(disabledByPolicy: false, enabled: true, helper: .off) },
            configuration: { nil },
            openURL: { opened.append($0) },
            requestPermission: { requested.append($0) }
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
