import Testing

@testable import CmuxSettingsUI

@Suite struct DesktopNotificationPermissionPresentationTests {
    @Test func authorizedStateShowsAllowedStatusAndSettingsAction() {
        let presentation = DesktopNotificationPermissionPresentation.make(for: .authorized)

        #expect(presentation.statusLabel == .allowed)
        #expect(presentation.subtitle == .allowed)
        #expect(presentation.primaryAction == .openSystemSettings)
        #expect(presentation.sendTestEnabled)
    }

    @Test func deniedStateShowsSystemSettingsAction() {
        let presentation = DesktopNotificationPermissionPresentation.make(for: .denied)

        #expect(presentation.statusLabel == .denied)
        #expect(presentation.subtitle == .denied)
        #expect(presentation.primaryAction == .openSystemSettings)
        #expect(presentation.sendTestEnabled)
    }
}
