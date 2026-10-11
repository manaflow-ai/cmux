#if os(iOS)
import Testing
import UIKit
@testable import CmuxMobileShellUI

@Suite struct TerminalComposerPromptEditorTests {
    @Test @MainActor func terminalComposerDisablesTextRewritingTraits() {
        let textView = UITextView()

        TerminalComposerPromptEditor.configureTextInputTraits(textView)

        #expect(textView.autocapitalizationType == .none)
        #expect(textView.autocorrectionType == .no)
        #expect(textView.spellCheckingType == .no)
        #expect(textView.smartQuotesType == .no)
        #expect(textView.smartDashesType == .no)
    }
}
#endif
