import Foundation

@MainActor
protocol SettingObservationStarting: AnyObject {
    func startObserving()
}

@MainActor
func startSettingsObservation(_ models: [any SettingObservationStarting]) {
    models.forEach { $0.startObserving() }
}

extension DefaultsValueModel: SettingObservationStarting {}
extension JSONValueModel: SettingObservationStarting {}
extension SecretValueModel: SettingObservationStarting {}
extension MobilePairingStatusModel: SettingObservationStarting {}
