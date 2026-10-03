import AppKit
import Foundation
import Testing
@testable import CmuxFoundation

@Suite struct CmuxPlainTextInputTests {
    @Test func installAppDefaultsTurnsEverySubstitutionOff() throws {
        let suiteName = "CmuxPlainTextInputTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        for key in CmuxPlainTextInput.substitutionDefaultsKeys {
            #expect(defaults.object(forKey: key) == nil)
        }

        CmuxPlainTextInput.installAppDefaults(defaults)

        let registrationDomain = defaults.volatileDomain(forName: UserDefaults.registrationDomain)
        for key in CmuxPlainTextInput.substitutionDefaultsKeys {
            #expect(registrationDomain[key] as? Bool == false, "\(key)")
        }

        defaults.set(true, forKey: CmuxPlainTextInput.substitutionDefaultsKeys[0])
        CmuxPlainTextInput.installAppDefaults(defaults)
        #expect(defaults.object(forKey: CmuxPlainTextInput.substitutionDefaultsKeys[0]) as? Bool == true)
        #expect(CmuxPlainTextInput.substitutionDefaultsKeys.contains("NSAutomaticQuoteSubstitutionEnabled"))
        #expect(CmuxPlainTextInput.substitutionDefaultsKeys.contains("NSAutomaticDashSubstitutionEnabled"))
    }

    @MainActor
    @Test func disableTypingSubstitutionsTurnsOffEveryTextViewSwitch() {
        let textView = NSTextView()
        textView.isAutomaticQuoteSubstitutionEnabled = true
        textView.isAutomaticDashSubstitutionEnabled = true
        textView.isAutomaticTextReplacementEnabled = true
        textView.isAutomaticSpellingCorrectionEnabled = true
        textView.isAutomaticDataDetectionEnabled = true
        textView.isAutomaticLinkDetectionEnabled = true
        textView.isAutomaticTextCompletionEnabled = true
        textView.smartInsertDeleteEnabled = true

        textView.cmuxDisableTypingSubstitutions()

        #expect(!textView.isAutomaticQuoteSubstitutionEnabled)
        #expect(!textView.isAutomaticDashSubstitutionEnabled)
        #expect(!textView.isAutomaticTextReplacementEnabled)
        #expect(!textView.isAutomaticSpellingCorrectionEnabled)
        #expect(!textView.isAutomaticDataDetectionEnabled)
        #expect(!textView.isAutomaticLinkDetectionEnabled)
        #expect(!textView.isAutomaticTextCompletionEnabled)
        #expect(!textView.smartInsertDeleteEnabled)
    }
}
