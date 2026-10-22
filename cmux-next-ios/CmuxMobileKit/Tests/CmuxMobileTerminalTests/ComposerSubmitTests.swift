import Testing
@testable import CmuxMobileTerminal

/// Codex QA F1: Send must submit the prompt in Codex.
@Suite struct ComposerSubmitTests {
    @Test func aDraftIsOnePasteThenASeparateReturn() {
        let submit = ComposerSubmit(text: "write a 120 line python script", pressReturn: true)
        #expect(submit.steps == [.paste("write a 120 line python script"), .enter])
        #expect(submit.delaysEnter)
        #expect(ComposerSubmit.enterDelay > .zero)
    }

    @Test func aMultiLineDraftIsOnePaste() {
        let submit = ComposerSubmit(text: "line one\nline two\nline three", pressReturn: true)
        #expect(submit.steps == [.paste("line one\nline two\nline three"), .enter])
    }

    @Test func anEmptySendIsABareReturnAtOnce() {
        let submit = ComposerSubmit(text: "", pressReturn: true)
        #expect(submit.steps == [.enter])
        #expect(!submit.delaysEnter)
    }

    /// TUI live check (2026-10-21): in vim, Send with `:q` inserted `:q` as
    /// text. vim takes a bracketed paste as text even in normal mode. In a
    /// full-screen app a one-line draft is typed, like keys; Return follows.
    @Test func aFullScreenAppGetsAOneLineDraftTyped() {
        let submit = ComposerSubmit(text: ":q", pressReturn: true, fullScreenApp: true)
        #expect(submit.steps == [.type(":q"), .enter])
        #expect(submit.delaysEnter)
        // Past an agent's paste-burst window (Codex QA F1), longer than after a paste.
        #expect(submit.enterWait == ComposerSubmit.typedEnterDelay)
        #expect(ComposerSubmit.typedEnterDelay >= .milliseconds(200))
        #expect(ComposerSubmit(text: "ls", pressReturn: true).enterWait == ComposerSubmit.enterDelay)
        #expect(ComposerSubmit(text: "", pressReturn: true).enterWait == nil)
        // Several lines stay one paste (a block of text for the app).
        #expect(ComposerSubmit(text: "a\nb", pressReturn: true, fullScreenApp: true).steps == [.paste("a\nb"), .enter])
        // The shell and main-screen programs keep the paste.
        #expect(ComposerSubmit(text: ":q", pressReturn: true, fullScreenApp: false).steps == [.paste(":q"), .enter])
    }

    @Test func sendWithoutReturnOnlyPastes() {
        #expect(ComposerSubmit(text: "ls", pressReturn: false).steps == [.paste("ls")])
    }
}

/// Codex QA F1 re-check: Send with an image and text submits in one go.
@Suite struct ComposerAttachmentSubmitTests {
    @Test func pathsAndTextAreOnePasteThenReturn() {
        let submit = ComposerSubmit(attachmentPaths: ["/Users/a/.cmux/attachments/Photo 1.jpeg"], text: "what is in this image")
        #expect(submit.steps == [.paste("'/Users/a/.cmux/attachments/Photo 1.jpeg' what is in this image"), .enter])
        #expect(submit.delaysEnter)
    }

    @Test func pathsAloneAreInsertedWithoutReturn() {
        let submit = ComposerSubmit(attachmentPaths: ["/tmp/a.png", "/tmp/b c.png"], text: "")
        #expect(submit.steps == [.paste("/tmp/a.png '/tmp/b c.png' ")])
    }

    @Test func sendWithoutReturnNeverPressesReturn() {
        #expect(ComposerSubmit(attachmentPaths: ["/tmp/a.png"], text: "hi", pressReturn: false).steps == [.paste("/tmp/a.png hi")])
    }

    @Test func quotesOnlyWhatNeedsIt() {
        #expect(ComposerSubmit.shellQuoted("/tmp/a.png") == "/tmp/a.png")
        #expect(ComposerSubmit.shellQuoted("/tmp/it's.png") == "'/tmp/it'\\''s.png'")
    }
}
