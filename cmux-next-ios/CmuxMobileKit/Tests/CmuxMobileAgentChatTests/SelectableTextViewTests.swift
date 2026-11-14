#if os(iOS)
import CmuxMobileMarkdown
import Testing
import UIKit

/// CMUX-33: Select Text shows a read-only text view where a range, not the whole block, is selected.
@MainActor
struct SelectableTextViewTests {
    @Test func selectsARangeAndStaysReadOnly() throws {
        let view = SelectableTextView("Every link frame is a fixed header.").makeTextView()
        #expect(view.isSelectable)
        #expect(!view.isEditable)
        view.selectedRange = NSRange(location: 6, length: 4)
        let range = try #require(view.selectedTextRange)
        #expect(view.text(in: range) == "link")
        #expect(view.canPerformAction(#selector(UIResponderStandardEditActions.copy(_:)), withSender: nil))
    }

    @Test func monospacedFollowsDynamicType() throws {
        let view = SelectableTextView("let x = 1", textStyle: .footnote, monospaced: true).makeTextView()
        let font = try #require(view.font)
        #expect(font.fontDescriptor.symbolicTraits.contains(.traitMonoSpace))
        #expect(view.adjustsFontForContentSizeCategory)
    }
}
#endif
