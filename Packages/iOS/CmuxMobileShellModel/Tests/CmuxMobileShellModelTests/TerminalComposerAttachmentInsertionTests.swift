import Testing
@testable import CmuxMobileShellModel

@Suite struct TerminalComposerAttachmentInsertionTests {
    @Test func quotesMacPathsAndSeparatesThemFromExistingDraftText() {
        let insertion = TerminalComposerAttachmentInsertion(
            path: "/tmp/Customer's report.pdf"
        )

        #expect(
            insertion.appending(to: "cat")
                == "cat '/tmp/Customer'\\''s report.pdf' "
        )
        #expect(
            insertion.appending(to: "cat ")
                == "cat '/tmp/Customer'\\''s report.pdf' "
        )
    }

    @Test func producesAStandaloneQuotedArgumentForAnEmptyDraft() {
        let insertion = TerminalComposerAttachmentInsertion(path: "/tmp/image.png")

        #expect(insertion.appending(to: "") == "'/tmp/image.png' ")
    }
}
