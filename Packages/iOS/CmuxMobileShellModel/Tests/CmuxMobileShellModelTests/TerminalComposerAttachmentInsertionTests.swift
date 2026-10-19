import Foundation
import Testing
@testable import CmuxMobileShellModel

@Suite struct TerminalComposerAttachmentInsertionTests {
    @Test func quotesPlainPathWithTrailingSeparator() {
        let insertion = TerminalComposerAttachmentInsertion(path: "/tmp/uploads/report.pdf")
        #expect(insertion.appending(to: "") == "'/tmp/uploads/report.pdf' ")
    }

    @Test func escapesInteriorSingleQuotes() {
        let insertion = TerminalComposerAttachmentInsertion(
            path: "/tmp/Customer's report.pdf"
        )
        #expect(
            insertion.appending(to: "cat")
                == "cat '/tmp/Customer'\\''s report.pdf' "
        )
    }

    @Test func appendsWithoutDoublingWhitespaceSeparators() {
        let first = TerminalComposerAttachmentInsertion(path: "/a.txt")
        let second = TerminalComposerAttachmentInsertion(path: "/b.txt")
        let composed = second.appending(to: first.appending(to: ""))
        #expect(composed == "'/a.txt' '/b.txt' ")
    }
}
