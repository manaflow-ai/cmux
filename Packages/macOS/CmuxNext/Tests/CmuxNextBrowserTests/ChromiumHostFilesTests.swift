import AppKit
@testable import CmuxNextBrowser
import Foundation
import Testing

/// Task p01-process-064 of plans/cmux-next/chrome-parity/p01-process.md: in host mode a page's file
/// chooser shows cmux's picker and its files go to the host as paths (feature
/// `chromiumHostFileDialogs`, ``ChromiumHostFiles``), and a person's close lets the page's
/// beforeunload decide in the host (`try_close` in the token form, `CEFTab+UserClose.swift`). Host-mode
/// cases attach a real `CEFHostStart` to the spy remote dylib ``FilesSpy`` and deliver each REPLY
/// through the C callback the attach gave it.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) struct ChromiumHostFilesTests {
    // MARK: The request and its answer

    @Test func theRequestKeepsTheShimsModeAndItsAnswerIsOneAbsolutePathPerLine() throws {
        #expect(ChromiumFileDialogRequest(mode: 1, acceptTypes: [], defaultPath: "").multiple == 1)
        #expect(ChromiumFileDialogRequest(mode: 3, acceptTypes: [], defaultPath: "a.txt").mode == .save)
        #expect(ChromiumFileDialogRequest(mode: 9, acceptTypes: [], defaultPath: "").mode == .open, "an unknown mode is not open one")
        #expect(ChromiumFileDialogRequest(mode: 0, acceptTypes: [], defaultPath: "").multiple == 0)

        let files = [URL(filePath: "/tmp/a b/c.txt"), URL(filePath: "/tmp/d.png")]
        #expect(ChromiumFileDialogRequest.paths(files) == "/tmp/a b/c.txt\n/tmp/d.png")
        #expect(ChromiumFileDialogRequest.paths(nil) == nil)
        #expect(ChromiumFileDialogRequest.paths([]) == nil)
        let web = try #require(URL(string: "https://a.test/x"))
        #expect(ChromiumFileDialogRequest.paths([web]) == nil, "a URL that is no file became a path")
        #expect(ChromiumFileDialogRequest.paths([URL(filePath: "/tmp/two\nlines"), URL(filePath: "/tmp/ok")]) == "/tmp/ok",
                "a path with a line break would reach Chromium as two paths")
    }

    // MARK: ChromiumHostFiles

    @Test func aChooserIsAnsweredOnceWithThePersonsFiles() throws {
        let panels = RecordingFileDialogs()
        let files = ChromiumHostFiles(panels: panels)
        var answers: [String] = []

        files.ask(5, browser: 7, request: ChromiumFileDialogRequest(mode: 1, acceptTypes: ["image/*"], defaultPath: ""), window: nil) {
            answers.append("\($0) \($1) \($2 ?? "nil")")
        }

        #expect(panels.requests.map(\.mode) == [.openMultiple])
        #expect(files.waiting == 1)
        panels.complete(0, with: [URL(filePath: "/tmp/x"), URL(filePath: "/tmp/y")])
        panels.complete(0, with: [URL(filePath: "/tmp/z")])
        #expect(answers == ["5 1 /tmp/x\n/tmp/y"], "a chooser was answered twice or not at all")
        #expect(files.asked == 1)
        #expect(files.answered == 1)
        #expect(files.waiting == 0)
    }

    @Test func aCancelledPickerAnswersACancel() {
        let panels = RecordingFileDialogs()
        let files = ChromiumHostFiles(panels: panels)
        var answers: [String] = []
        files.ask(2, browser: 7, request: ChromiumFileDialogRequest(mode: 3, acceptTypes: [], defaultPath: "/tmp/a.txt"), window: nil) {
            answers.append("\($0) \($1) \($2 ?? "nil")")
        }

        panels.complete(0, with: nil)

        #expect(answers == ["2 0 nil"])
    }

    /// `debug.cef` `file_dialog_choose`: the newest chooser takes the files, its picker goes down,
    /// and the picker's own cancel after that answers nothing.
    @Test func theNewestChooserTakesADebugChoiceAndItsPickerGoes() {
        let panels = RecordingFileDialogs()
        let files = ChromiumHostFiles(panels: panels)
        var answers: [String] = []
        let record: ChromiumHostFiles.Answer = { answers.append("\($0) \($1) \($2 ?? "nil")") }
        files.ask(3, browser: 7, request: ChromiumFileDialogRequest(mode: 0, acceptTypes: [], defaultPath: ""), window: nil, answer: record)
        files.ask(4, browser: 8, request: ChromiumFileDialogRequest(mode: 0, acceptTypes: [], defaultPath: ""), window: nil, answer: record)

        #expect(files.answerNewest(with: [URL(filePath: "/tmp/z")]))
        panels.complete(1, with: nil)

        #expect(answers == ["4 0 /tmp/z"])
        #expect(panels.ended == [4], "the debug choice took down another chooser's picker")
        #expect(panels.showing == [3])
        #expect(files.waiting == 1)
        #expect(files.answerNewest(with: nil))
        #expect(answers == ["4 0 /tmp/z", "3 0 nil"])
        #expect(!files.answerNewest(with: nil), "a debug choice with no chooser said it answered one")
    }

    /// Chromium cancels a closed browser's choosers itself (`CancelFileDialogs`): cmux takes their
    /// pickers down and sends nothing; the host's end takes every picker down.
    @Test func aClosedBrowsersChoosersEndUnanswered() {
        let panels = RecordingFileDialogs()
        let files = ChromiumHostFiles(panels: panels)
        var answers: [String] = []
        let record: ChromiumHostFiles.Answer = { answers.append("\($0) \($1) \($2 ?? "nil")") }
        files.ask(1, browser: 7, request: ChromiumFileDialogRequest(mode: 0, acceptTypes: [], defaultPath: ""), window: nil, answer: record)
        files.ask(2, browser: 8, request: ChromiumFileDialogRequest(mode: 0, acceptTypes: [], defaultPath: ""), window: nil, answer: record)

        files.browserClosed(7)
        panels.complete(0, with: [URL(filePath: "/tmp/late")])

        #expect(answers.isEmpty, "a closed browser's chooser was answered")
        #expect(panels.ended == [1])
        #expect(files.waiting == 1)
        files.hostEnded()
        #expect(panels.ended == [1, 2])
        #expect(files.waiting == 0)
        #expect(answers.isEmpty)
    }

    /// Before, the pickers were kept by window: two choosers on one window, or both with none,
    /// shared one picker slot, so closing one browser cancelled the other's picker (a cancel its
    /// person never chose) and left the closed page's picker up.
    @Test(arguments: [true, false])
    func closingOneBrowserLeavesAnotherChooserOnTheSameWindowWaiting(sharesAWindow: Bool) {
        let window: NSWindow? = sharesAWindow
            ? NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: true)
            : nil
        let panels = RecordingFileDialogs()
        let files = ChromiumHostFiles(panels: panels)
        var answers: [String] = []
        let record: ChromiumHostFiles.Answer = { answers.append("\($0) \($1) \($2 ?? "nil")") }
        files.ask(1, browser: 7, request: ChromiumFileDialogRequest(mode: 0, acceptTypes: [], defaultPath: ""), window: window, answer: record)
        files.ask(2, browser: 8, request: ChromiumFileDialogRequest(mode: 0, acceptTypes: [], defaultPath: ""), window: window, answer: record)
        #expect(panels.windows.allSatisfy { $0 === window }, "a picker was not shown on its page's window")

        files.browserClosed(7)

        #expect(panels.ended == [1], "closing browser 7 took down another chooser's picker")
        #expect(panels.showing == [2], "browser 8's picker went down, or browser 7's stayed up")
        #expect(answers.isEmpty, "browser 8's chooser was answered with a cancel nobody chose")
        #expect(files.waiting == 1)
        panels.complete(1, with: [URL(filePath: "/tmp/b8")])
        #expect(answers == ["2 0 /tmp/b8"], "browser 8's choice was lost")
    }

    // MARK: The runtime

    /// Before, every FILE_DIALOG was cancelled and the host never sent one: Chromium's own panel opened
    /// in the host, a window of the host's and the host frontmost.
    @Test func hostModeTurnsChoosersOnAndSendsThePersonsFilesAsPaths() async throws {
        FilesSpy.reset()
        let panels = RecordingFileDialogs()
        let (runtime, _) = try await FilesHarness.hostRuntime(fileDialogs: panels)
        let shim = try #require(runtime.shim)

        runtime.answerHostFileDialogs(shim)
        #expect(FilesSpy.calls == ["set_file_dialogs 1"])
        runtime.handle(.fileDialog(browser: 7, dialogID: 2, mode: 0, acceptTypes: ["image/*"], defaultPath: ""))
        #expect(panels.requests == [ChromiumFileDialogRequest(mode: 0, acceptTypes: ["image/*"], defaultPath: "")])
        #expect(FilesSpy.calls == ["set_file_dialogs 1"], "the chooser was answered before the person chose")
        panels.complete(0, with: [URL(filePath: "/tmp/a.png")])

        #expect(FilesSpy.calls == ["set_file_dialogs 1", "file_dialog_answer 2 0 /tmp/a.png"])
        runtime.handle(.fileDialog(browser: 7, dialogID: 3, mode: 1, acceptTypes: [], defaultPath: ""))
        runtime.handle(.beforeClose(browser: 7))
        #expect(panels.ended == [3], "a closed page's picker stayed up")
    }

    /// Without cmux's picker (in process, or the feature off) a chooser the shim sends is cancelled at
    /// once and choosers stay off, so Chromium's own panel shows and a page never waits.
    @Test func withoutAPickerAChooserIsCancelledAndChoosersStayOff() async throws {
        FilesSpy.reset()
        let runtime = try FilesHarness.inProcessRuntime()
        let shim = try #require(runtime.shim)

        runtime.answerHostFileDialogs(shim)
        runtime.handle(.fileDialog(browser: 7, dialogID: 4, mode: 0, acceptTypes: [], defaultPath: ""))

        #expect(FilesSpy.calls == ["file_dialog_answer 4 0 nil"])
        let (hostRuntime, _) = try await FilesHarness.hostRuntime(fileDialogs: nil)
        FilesSpy.calls = []
        hostRuntime.answerHostFileDialogs(try #require(hostRuntime.shim))
        #expect(FilesSpy.calls.isEmpty, "choosers went on with no picker to answer them")
    }

    // MARK: A person's close

    /// Before, the remote's "sent" (1) read as "closes now": the tab closed at once and the page's
    /// beforeunload never asked. Now the page decides; its REPLY closes nothing by itself.
    @Test func hostModeAPersonsCloseLetsThePageDecide() async throws {
        FilesSpy.reset()
        let (runtime, _) = try await FilesHarness.hostRuntime(fileDialogs: nil)
        let (tab, intents) = FilesHarness.registeredTab(runtime)

        #expect(tab.beginUserClose(), "the host's stand-in answer closed the tab before its page decided")
        #expect(FilesSpy.calls == ["try_close 7"])
        try FilesHarness.deliver(try #require(FilesSpy.tokens.last), CEFReplyWaitersTests.int32(0))

        #expect(intents.closes == 0, "the page's answer closed the tab; only its BEFORE_CLOSE may")
        #expect(!tab.isClosed)
    }

    /// A close no answer can come for (the host ended) closes the tab: the person asked for it.
    @Test func hostModeACloseTheHostCannotAnswerClosesTheTab() async throws {
        FilesSpy.reset()
        let (runtime, _) = try await FilesHarness.hostRuntime(fileDialogs: nil)
        let (tab, intents) = FilesHarness.registeredTab(runtime)

        #expect(tab.beginUserClose())
        runtime.hostGone()

        #expect(intents.closes == 1)
    }

    @Test func inProcessTheCallsOwnAnswerDecides() throws {
        FilesSpy.reset()
        let runtime = try FilesHarness.inProcessRuntime()
        let (tab, intents) = FilesHarness.registeredTab(runtime)

        FilesSpy.tryCloseResult = 1
        #expect(!tab.beginUserClose(), "a page that closes now kept its tab")
        FilesSpy.tryCloseResult = 0
        #expect(tab.beginUserClose(), "a page whose beforeunload runs lost its tab")
        #expect(intents.closes == 0)
    }
}

/// The pickers a test stands in for: each request, completed when the test says. Ending a chooser
/// cancels only its own picker, as ``ChromiumFileDialogPanels`` does.
@MainActor final class RecordingFileDialogs: ChromiumFileDialogAnswering {
    private(set) var requests: [ChromiumFileDialogRequest] = []
    private(set) var windows: [NSWindow?] = []
    private var dialogs: [Int32] = []
    private var completions: [@MainActor ([URL]?) -> Void] = []
    /// The choosers whose picker is up.
    private(set) var showing: Set<Int32> = []
    /// The choosers whose picker was taken down, in order.
    private(set) var ended: [Int32] = []

    func answerFileDialog(_ dialog: Int32, request: ChromiumFileDialogRequest, window: NSWindow?,
                          completion: @escaping @MainActor ([URL]?) -> Void) {
        requests.append(request)
        windows.append(window)
        dialogs.append(dialog)
        completions.append(completion)
        showing.insert(dialog)
    }

    func endFileDialog(_ dialog: Int32) {
        ended.append(dialog)
        guard showing.contains(dialog), let index = dialogs.firstIndex(of: dialog) else { return }
        complete(index, with: nil)
    }

    /// Runs picker `index`'s completion, as the person's choice (nil: cancel) would.
    func complete(_ index: Int, with urls: [URL]?) {
        showing.remove(dialogs[index])
        completions[index](urls)
    }
}

/// The close intents a tab asked for.
@MainActor final class CloseIntents: BrowserTabDelegate {
    private(set) var closes = 0

    func browserTab(_ tab: any BrowserTab, didRequest intent: BrowserTabIntent) {
        if case .close = intent { closes += 1 }
    }
}

/// Runtimes for ``ChromiumHostFilesTests``: in process or in host mode against ``FilesSpy``.
@MainActor enum FilesHarness {
    static func inProcessRuntime() throws -> CEFRuntime {
        let runtime = CEFRuntime(shim: try CEFShimLibrary.resolving(FilesSpy.symbol), storage: HostRepliesHarness.storage())
        // Tabs and panes hold the runtime unowned and may schedule work past the test.
        _ = Unmanaged.passRetained(runtime)
        return runtime
    }

    static func hostRuntime(fileDialogs: (any ChromiumFileDialogAnswering)?) async throws -> (CEFRuntime, CEFHostStart) {
        let runtime = try inProcessRuntime()
        let host = CEFHostStart(supervisor: OneSpyHost(), fileDialogs: fileDialogs, open: { _ in
            do throws(CEFShimLibrary.LoadError) { return .success(try CEFRemoteShim.make(symbol: FilesSpy.symbol, expected: FilesSpy.abi)) } catch { return .failure(.shim(error)) }
        })
        guard case .success = await host.attached() else { throw BrowserTabError.closed }
        runtime.hostStart = host
        #expect(FilesSpy.replySink?.context != nil, "the attach gave the remote shim no reply sink")
        return (runtime, host)
    }

    /// A tab of a new pane, registered as browser 7, and the intents it asks for.
    static func registeredTab(_ runtime: CEFRuntime) -> (CEFTab, CloseIntents) {
        let tab = HostRepliesHarness.tab(in: HostRepliesHarness.pane(runtime, profile: .default).0)
        runtime.register(tab, browser: 7)
        let intents = CloseIntents()
        tab.delegate = intents
        // The tab holds its delegate weakly; the test's intents outlive it.
        _ = Unmanaged.passRetained(intents)
        FilesSpy.calls = []
        return (tab, intents)
    }

    static func deliver(_ token: UInt32, _ fields: [UInt8]) throws {
        let sink = try #require(FilesSpy.replySink)
        let reply = try #require(sink.reply)
        fields.withUnsafeBytes { reply(sink.context, token, $0.baseAddress, $0.count) }
    }
}

/// The shim and remote dylib for these tests: the wire entry points (attach says hello at once,
/// set_reply keeps the REPLY sink), and `set_file_dialogs`, `file_dialog_answer` and `try_close`,
/// which record their calls. `try_close` makes the next token current, as PostForReply does, and
/// answers ``tryCloseResult`` (in host mode the remote's own "sent", 1). Every other function returns 0.
nonisolated enum FilesSpy {
    static let abi = "files-spy-abi"
    // crash-allow: test-only spy state, read and written on the main thread by a serialized suite and the C stand-ins it calls there
    nonisolated(unsafe) static var lastToken: UInt32 = 0
    // crash-allow: test-only spy state (see lastToken)
    nonisolated(unsafe) static var tokens: [UInt32] = []
    // crash-allow: test-only spy state (see lastToken)
    nonisolated(unsafe) static var calls: [String] = []
    // crash-allow: test-only spy state (see lastToken)
    nonisolated(unsafe) static var tryCloseResult: Int32 = 1
    // crash-allow: test-only spy state (see lastToken)
    nonisolated(unsafe) static var replySink: (context: UnsafeMutableRawPointer?, reply: CEFRemoteShim.ReplyFn?)?
    // crash-allow: a C string made once and never freed, read only
    nonisolated(unsafe) private static let abiCString = strdup(abi)

    static func reset() {
        lastToken = 0
        tokens = []
        calls = []
        tryCloseResult = 1
        replySink = nil
    }

    static func symbol(_ name: String) -> UnsafeMutableRawPointer? {
        let abiID: @convention(c) () -> UnsafePointer<CChar>? = { UnsafePointer(FilesSpy.abiCString) }
        let attach: CEFRemoteShim.AttachFn = { _, _, _, context, hello in
            hello?(context, 1, nil)
            return 1
        }
        let detach: CEFRemoteShim.DetachFn = {}
        let setReply: CEFRemoteShim.SetReplyFn = { context, reply in FilesSpy.replySink = (context, reply) }
        let lastReplyToken: CEFRemoteShim.LastReplyTokenFn = { FilesSpy.lastToken }
        let setFileDialogs: @convention(c) (Int32) -> Void = { FilesSpy.calls.append("set_file_dialogs \($0)") }
        let fileDialogAnswer: @convention(c) (Int32, Int32, UnsafePointer<CChar>?) -> Int32 = { dialog, multiple, paths in
            FilesSpy.calls.append("file_dialog_answer \(dialog) \(multiple) \(paths.map { String(cString: $0) } ?? "nil")")
            return 1
        }
        let tryClose: @convention(c) (Int32) -> Int32 = { browser in
            FilesSpy.calls.append("try_close \(browser)")
            FilesSpy.lastToken = 100 + UInt32(FilesSpy.tokens.count)
            FilesSpy.tokens.append(FilesSpy.lastToken)
            return FilesSpy.tryCloseResult
        }
        let nothing: @convention(c) () -> Int = { 0 }
        return switch name {
        case "cmux_shim_abi_id": unsafeBitCast(abiID, to: UnsafeMutableRawPointer.self)
        case "cmux_remote_shim_attach": unsafeBitCast(attach, to: UnsafeMutableRawPointer.self)
        case "cmux_remote_shim_detach": unsafeBitCast(detach, to: UnsafeMutableRawPointer.self)
        case "cmux_remote_shim_set_reply": unsafeBitCast(setReply, to: UnsafeMutableRawPointer.self)
        case "cmux_remote_shim_last_reply_token": unsafeBitCast(lastReplyToken, to: UnsafeMutableRawPointer.self)
        case "cmux_shim_set_file_dialogs": unsafeBitCast(setFileDialogs, to: UnsafeMutableRawPointer.self)
        case "cmux_shim_file_dialog_answer": unsafeBitCast(fileDialogAnswer, to: UnsafeMutableRawPointer.self)
        case "cmux_shim_try_close": unsafeBitCast(tryClose, to: UnsafeMutableRawPointer.self)
        default: unsafeBitCast(nothing, to: UnsafeMutableRawPointer.self)
        }
    }
}
