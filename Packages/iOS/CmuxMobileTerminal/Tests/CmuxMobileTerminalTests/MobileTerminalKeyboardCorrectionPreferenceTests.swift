#if canImport(UIKit)
import Foundation
import Testing
import UIKit

@testable import CmuxMobileTerminal

@MainActor
@Suite("Mobile terminal keyboard corrections")
struct MobileTerminalKeyboardCorrectionPreferenceTests {
    private func freshDefaults(_ name: String) throws -> UserDefaults {
        let suiteName = "MobileTerminalKeyboardCorrectionPreferenceTests.\(name).\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    @Test("keyboard corrections default off without writing the default")
    func defaultsOffWithoutWriting() throws {
        let defaults = try freshDefaults("defaults")
        let preference = MobileTerminalKeyboardCorrectionPreference(defaults: defaults)

        #expect(preference.isEnabled == false)
        #expect(
            defaults.object(forKey: MobileTerminalKeyboardCorrectionPreference.enabledDefaultsKey)
                == nil
        )
    }

    @Test("enabling keyboard corrections persists across preference instances")
    func enablingPersistsAcrossInstances() throws {
        let defaults = try freshDefaults("persists")
        let preference = MobileTerminalKeyboardCorrectionPreference(defaults: defaults)

        preference.isEnabled = true

        #expect(defaults.bool(forKey: MobileTerminalKeyboardCorrectionPreference.enabledDefaultsKey))
        #expect(MobileTerminalKeyboardCorrectionPreference(defaults: defaults).isEnabled)
    }

    @Test("terminal input traits follow the preference")
    func inputTraitsFollowPreference() throws {
        let defaults = try freshDefaults("traits")
        let preference = MobileTerminalKeyboardCorrectionPreference(defaults: defaults)
        let view = TerminalInputTextView(keyboardCorrectionPreference: preference)

        #expect(view.autocorrectionType == .no)
        #expect(view.spellCheckingType == .no)
        #expect(view.smartInsertDeleteType == .no)
        #expect(view.inlinePredictionType == .no)

        preference.isEnabled = true
        #expect(view.autocorrectionType == .yes)
        #expect(view.spellCheckingType == .yes)
        #expect(view.smartInsertDeleteType == .yes)
        #expect(view.inlinePredictionType == .yes)
    }

    @Test("enabled corrections do not rewrite committed terminal input")
    func enabledCorrectionsLeaveCommittedInputLiteral() throws {
        let defaults = try freshDefaults("literal-input")
        let preference = MobileTerminalKeyboardCorrectionPreference(defaults: defaults)
        let view = TerminalInputTextView(keyboardCorrectionPreference: preference)
        var committed: [String] = []
        view.onText = { committed.append($0) }

        preference.isEnabled = true
        view.insertText("git stauts")

        #expect(committed == ["git stauts"])
    }
}
#endif
