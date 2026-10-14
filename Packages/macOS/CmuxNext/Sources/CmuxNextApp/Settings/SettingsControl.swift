import CmuxNextActions
import CmuxNextControl
import CmuxNextSettings
import Foundation

/// `settings.open {section?, setting?, focus?}` (R82): opens Settings through the same path as
/// Settings…, Cmd-, and the palette (`SettingsWindowService.show`). `setting` is a cmux.json key
/// (the page focuses its row) or another name `SettingsAnchor(key:)` knows; `focus` false opens
/// the tab without selecting it. The CLI verb `cmux settings open` calls this method.
///
/// `computer_use.status`: the Settings Computer Use card's state (`ComputerUseSetup.pageJSON`:
/// phase, the helper's Accessibility and Screen Recording grants, null while unknown, and the
/// helper's name) for `cmux agents doctor`. Read-only: it never prompts and never changes a
/// setting or a grant. The first call may make the model, which applies its inputs at once
/// (`starting` while the helper's grants are read, never a stale `off`) and reads the grants.
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
            // Main actor because `ComputerUseSetup` is a main-actor model; one read per doctor run.
            .mainActor("computer_use.status") { [weak services] _ in
                .value(services?.onboarding.computerUseSetup.pageJSON ?? .null)
            },
        ]
    }
}
