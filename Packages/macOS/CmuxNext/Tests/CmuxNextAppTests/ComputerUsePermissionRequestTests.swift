import CmuxNextOnboarding
@testable import CmuxNextApp
import Foundation
import Testing

@MainActor struct ComputerUsePermissionRequestTests {
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
