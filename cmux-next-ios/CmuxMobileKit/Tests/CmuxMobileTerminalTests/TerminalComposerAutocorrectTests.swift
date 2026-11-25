#if os(iOS)
import CmuxMobileDesign
import Foundation
import Testing
import UIKit
@testable import CmuxMobileTerminal

/// Leo, 2026-11-24: "an autocorect toggle in the terminal composer would be
/// good... i am talking to claude cli via phone". Off by default (a shell
/// line is not prose); on, the field corrects, spell-checks and predicts.
@MainActor
@Suite struct TerminalComposerAutocorrectTests {
    @Test func offByDefault() throws {
        let defaults = try #require(UserDefaults(suiteName: "autocorrect-\(UUID().uuidString)"))
        #expect(CmuxMobilePreferences.terminalComposerAutocorrect(defaults) == false)
        defaults.set(true, forKey: CmuxMobilePreferences.Key.terminalComposerAutocorrect)
        #expect(CmuxMobilePreferences.terminalComposerAutocorrect(defaults) == true)
    }

    @Test func onTurnsCorrectionSpellingAndPredictionOn() {
        let view = UITextView()
        #expect(ComposerTextView.applyAutocorrect(true, to: view))
        #expect(view.autocorrectionType == .yes)
        #expect(view.spellCheckingType == .yes)
        #expect(view.inlinePredictionType == .default)
        // No change, nothing to reload.
        #expect(ComposerTextView.applyAutocorrect(true, to: view) == false)
    }

    @Test func offKeepsTheShellLineAsTyped() {
        let view = UITextView()
        ComposerTextView.applyAutocorrect(true, to: view)
        #expect(ComposerTextView.applyAutocorrect(false, to: view))
        #expect(view.autocorrectionType == .no)
        #expect(view.spellCheckingType == .no)
        #expect(view.inlinePredictionType == .no)
    }
}
#endif
