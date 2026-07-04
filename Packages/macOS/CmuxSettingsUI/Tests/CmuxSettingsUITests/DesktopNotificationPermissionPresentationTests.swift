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
        #expect(!presentation.sendTestEnabled)
    }

    @Test func unknownStateDisablesSendTestUntilPermissionRefreshCompletes() {
        let presentation = DesktopNotificationPermissionPresentation.make(for: .unknown)

        #expect(presentation.statusLabel == .unknown)
        #expect(presentation.subtitle == nil)
        #expect(presentation.primaryAction == nil)
        #expect(!presentation.sendTestEnabled)
    }

    @Test func notDeterminedStateDisablesSendTestUntilUserEnablesPermission() {
        let presentation = DesktopNotificationPermissionPresentation.make(for: .notDetermined)

        #expect(presentation.statusLabel == .notRequested)
        #expect(presentation.subtitle == .notDetermined)
        #expect(presentation.primaryAction == .requestAuthorization)
        #expect(!presentation.sendTestEnabled)
    }

    @Test func provisionalStateShowsDeliverQuietlyStatusAndAllowsSendTest() {
        let presentation = DesktopNotificationPermissionPresentation.make(for: .provisional)

        #expect(presentation.statusLabel == .deliverQuietly)
        #expect(presentation.subtitle == .allowed)
        #expect(presentation.primaryAction == .openSystemSettings)
        #expect(presentation.sendTestEnabled)
    }

    @Test func ephemeralStateShowsTemporaryStatusAndAllowsSendTest() {
        let presentation = DesktopNotificationPermissionPresentation.make(for: .ephemeral)

        #expect(presentation.statusLabel == .temporary)
        #expect(presentation.subtitle == .allowed)
        #expect(presentation.primaryAction == .openSystemSettings)
        #expect(presentation.sendTestEnabled)
    }
}
