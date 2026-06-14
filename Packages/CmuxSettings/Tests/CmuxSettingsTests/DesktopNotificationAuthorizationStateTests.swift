import Testing
@testable import CmuxSettings

@Suite("DesktopNotificationAuthorizationState")
struct DesktopNotificationAuthorizationStateTests {
    @Test(arguments: [
        DesktopNotificationAuthorizationState.authorized,
        .provisional,
        .ephemeral,
    ])
    func deliveryAllowedStatesPermitDesktopDelivery(state: DesktopNotificationAuthorizationState) {
        #expect(state.allowsDesktopDelivery)
    }

    @Test(arguments: [
        DesktopNotificationAuthorizationState.unknown,
        .notDetermined,
        .denied,
    ])
    func unavailableStatesDoNotPermitDesktopDelivery(state: DesktopNotificationAuthorizationState) {
        #expect(!state.allowsDesktopDelivery)
    }
}
