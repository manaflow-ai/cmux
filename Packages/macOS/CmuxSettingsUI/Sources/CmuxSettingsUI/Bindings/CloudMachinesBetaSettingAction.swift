import Foundation

/// The Cloud opt-in action used by the Settings toggle.
@MainActor
struct CloudMachinesBetaSettingAction {
    let model: DefaultsValueModel<Bool>
    let notificationCenter: NotificationCenter

    init(model: DefaultsValueModel<Bool>, notificationCenter: NotificationCenter = .default) {
        self.model = model
        self.notificationCenter = notificationCenter
    }

    func setEnabled(_ enabled: Bool) {
        model.set(enabled)
        notificationCenter.post(name: Notification.Name("rightSidebarBetaFeatureDidChange"), object: nil)
    }
}
