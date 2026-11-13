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

    /// Live logs (2026-11-13): a paste and its Return sent as two requests
    /// lost the Return when the link stalled between them. A paste followed
    /// by Return is one unit a submit-capable session takes as one request;
    /// typed text (a full-screen app) keeps its delayed Return.
    @Test func aPasteAndItsReturnAreOneUnit() {
        #expect(ComposerSubmit(text: "echo hi", pressReturn: true).pasteThenReturn == "echo hi")
        #expect(ComposerSubmit(text: "a\nb", pressReturn: true, fullScreenApp: true).pasteThenReturn == "a\nb")
        #expect(ComposerSubmit(attachmentPaths: ["/tmp/a.png"], text: "hi").pasteThenReturn == "/tmp/a.png hi")
        #expect(ComposerSubmit(text: ":q", pressReturn: true, fullScreenApp: true).pasteThenReturn == nil)
        #expect(ComposerSubmit(text: "ls", pressReturn: false).pasteThenReturn == nil)
        #expect(ComposerSubmit(text: "", pressReturn: true).pasteThenReturn == nil)
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

#if os(iOS) && DEBUG
import CmuxMobileArtifacts
import Foundation
import UIKit

/// Live logs (2026-11-13, "41 typed bytes not sent again"): Send went as two
/// requests, the paste and a Return 60 ms later. When the link stalled
/// between them the Return was dropped (never sent twice) after the text had
/// been typed, and the shell glued it onto the next command. Through the real
/// screen and Ghostty surface: on a session that takes text and Return in one
/// request (`TerminalSession.submit`), the paste and its Return are never two
/// separate sends.
@MainActor
@Suite(.serialized) struct ComposerSubmitScreenTests {
    @MainActor
    final class SubmitSession: TerminalSession {
        let programName = "zsh"
        let isAlternateScreen = false
        private(set) var handler: (@MainActor (TerminalSessionEvent) -> Void)?
        /// Takes text and Return in one request (a daemon with send-expect-agent-v1).
        var takesSubmit = true
        /// Each write, in order: `submit` marks a payload whose Return went with it.
        private(set) var writes: [(bytes: Data, submit: Bool)] = []

        func start(_ handler: @escaping @MainActor (TerminalSessionEvent) -> Void) { self.handler = handler }
        func send(_ bytes: Data) { writes.append((bytes, false)) }
        func submit(_ payload: Data) -> Bool {
            guard takesSubmit else {
                send(payload)
                return false
            }
            writes.append((payload, true))
            return true
        }
        func resize(columns: Int, rows: Int) {}
        func stop() {}
        func write(_ bytes: Data) { handler?(.output(bytes)) }
    }

    struct Screen {
        let model: TerminalModel
        let session: SubmitSession
        let window: UIWindow

        func close() {
            window.isHidden = true
            window.rootViewController = nil
        }
    }

    static func makeScreen(_ session: SubmitSession, setup: String = "") async throws -> Screen {
        let model = TerminalModel(session: session, artifactSource: MockArtifactSource(), title: "submit")
        let screen = TerminalViewController(model: model)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = screen
        window.makeKeyAndVisible()
        try await TerminalPredictionInputTests.waitUntil(5) { session.handler != nil && screen.surface.prediction != nil }
        try #require(session.handler != nil, "the screen never started its session")
        session.write(Data((setup + "$ ").utf8))
        try await Task.sleep(for: .milliseconds(300)) // test: the prompt's frames land
        return Screen(model: model, session: session, window: window)
    }

    /// Past every wait a Return may follow its text with (`ComposerSubmit`).
    static let pastTheReturn = ComposerSubmit.typedEnterDelay + .milliseconds(250)

    @Test func aPasteAndItsReturnAreOneRequest() async throws {
        await TerminalScreenTestLock.acquire()
        defer { TerminalScreenTestLock.release() }
        let screen = try await Self.makeScreen(SubmitSession())
        defer { screen.close() }
        screen.model.composerText = "echo hi"
        screen.model.send()
        try await Task.sleep(for: Self.pastTheReturn) // test: a separate Return would have gone by now
        let writes = screen.session.writes
        #expect(writes.count == 1, "the paste and its Return went as \(writes.count) requests")
        #expect(writes.first.map { String(decoding: $0.bytes, as: UTF8.self) } == "echo hi")
        #expect(writes.first?.submit == true)
    }

    /// A session that cannot take both in one request: the paste, then
    /// Return as its own write, as before.
    @Test func withoutSubmitReturnFollowsAsItsOwnWrite() async throws {
        await TerminalScreenTestLock.acquire()
        defer { TerminalScreenTestLock.release() }
        let session = SubmitSession()
        session.takesSubmit = false
        let screen = try await Self.makeScreen(session)
        defer { screen.close() }
        screen.model.composerText = "echo hi"
        screen.model.send()
        try await TerminalPredictionInputTests.waitUntil(2) { session.writes.count == 2 }
        #expect(session.writes.map { String(decoding: $0.bytes, as: UTF8.self) } == ["echo hi", "\r"])
        #expect(session.writes.allSatisfy { !$0.submit })
    }

    /// vim and other full-screen apps: a one-line draft is typed and Return
    /// waits past an agent's paste-burst window (Codex QA F1), unchanged.
    @Test func aFullScreenAppKeepsTypedTextAndItsDelayedReturn() async throws {
        await TerminalScreenTestLock.acquire()
        defer { TerminalScreenTestLock.release() }
        let session = SubmitSession()
        let screen = try await Self.makeScreen(session, setup: "\u{1B}[?1049h")
        defer { screen.close() }
        session.handler?(.alternateScreen(true))
        try #require(screen.model.isTUI, "the alternate screen did not register")
        screen.model.composerText = ":q"
        screen.model.send()
        let typed = { session.writes.map { String(decoding: $0.bytes, as: UTF8.self) } }
        try await TerminalPredictionInputTests.waitUntil(2) { typed().joined() == ":q\r" }
        #expect(typed().joined() == ":q\r")
        #expect(typed().last == "\r", "Return is its own write")
        #expect(session.writes.allSatisfy { !$0.submit })
    }
}
#endif
