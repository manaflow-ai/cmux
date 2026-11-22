import CmuxNextActions
import CmuxNextControl
import CmuxNextSettings
import Foundation

/// `settings.open {section?, setting?, focus?}` (R82): opens Settings through the same path as
/// Settings…, Cmd-, and the palette (`SettingsWindowService.show`). `setting` is a cmux.json key
/// (the page focuses its row) or another name `SettingsAnchor(key:)` knows; `focus` false opens
/// the tab without selecting it. The CLI verb `cmux settings open` calls this method.
enum SettingsControl {
    static func methods(services: AppServices) -> [ControlMethod] {
        [
            .mainActor("settings.open") { [weak services] call in
                var section: SettingsSection?
                if let name = call.params["section"]?.stringValue {
                    guard let parsed = SettingsSection(rawValue: name) else {
                        throw ControlError.invalidParams(
                            "section must be one of \(SettingsSection.allCases.map(\.rawValue).joined(separator: ", "))")
                    }
                    section = parsed
                }
                let setting = call.params["setting"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
                guard let services else { return .value(.null) }
                do {
                    try services.settingsWindow.show(section: section, setting: setting, focus: call.params["focus"]?.boolValue ?? true)
                } catch let failure as ActionFailure {
                    throw ControlError.invalidParams(failure.message)
                }
                return .value(["opened": true])
            },
        ]
    }
}
