import Foundation

@MainActor
protocol SettingObservationStarting: AnyObject {
    func startObserving()
}

extension DefaultsValueModel: SettingObservationStarting {}
extension JSONValueModel: SettingObservationStarting {}
extension SecretValueModel: SettingObservationStarting {}
extension MobilePairingStatusModel: SettingObservationStarting {}
