#if DEBUG
// The Chromium host app ships in Debug builds only (embed-cef.sh), and so does its text input.
import AppKit
@testable import CmuxNextBrowser
import CmuxNextCompat
import Foundation
import Testing

/// Host IME: the page view's ops reach the host's shim as its IME exports, with
/// the kIme frame's byte layouts, and nothing goes when the host's shim lacks them.
extension ChromiumHostTextInputTests {
    static let imeExports: Set<String> = ["cmux_shim_browser_ime_set_composition", "cmux_shim_browser_ime_commit_text",
                                          "cmux_shim_browser_ime_finish_composing",
                                          "cmux_shim_browser_ime_cancel_composition"]

    @Test func theOpsGoToTheHostsIMEExportsInOrder() throws {
        let shim = try CEFShimLibrary.resolving(IMESpy.symbol, hostExports: Self.imeExports)
        let ops = shim.textInput
        #expect(ops.isComplete)
        IMESpy.calls.withLock { $0 = [] }
        let clauses = [ChromiumHostCompositionClause(range: 0..<2, thick: true)]
        #expect(ops.send(.setComposition(text: "日本", clauses: clauses, selection: 2..<2, replacement: nil), browser: 7))
        #expect(ops.send(.commitText("日本", replacement: 1..<3), browser: 7))
        #expect(ops.send(.finishComposing, browser: 7))
        #expect(ops.send(.cancelComposition, browser: 7))
        #expect(!ops.send(.keyCommands(["DeleteBackward"]), browser: 7))
        #expect(!ops.send(.editCommand("SelectAll"), browser: 7))
        let text = ChromiumHostTextInputBytes.utf16LE("日本")
        #expect(text == [0xe5, 0x65, 0x2c, 0x67])
        #expect(IMESpy.calls.withLock { $0 } == [
            .set(browser: 7, text: text, clauses: ChromiumHostTextInputBytes.clauses(clauses), selection: [2, 2], replace: [-1, -1]),
            .commit(browser: 7, text: text, replace: [1, 3]),
            .finish(browser: 7),
            .cancel(browser: 7),
        ])
    }

    /// The kIme frame's payload is the same text and clause bytes.
    @Test func theShimOpsAndTheImeFrameShareTheirBytes() {
        let clauses = [ChromiumHostCompositionClause(range: 0..<1, thick: false, color: 0xFF11_2233)]
        let frame = ChromiumHostFrame(textInput: .setComposition(text: "😀", clauses: clauses, selection: 0..<2,
                                                                 replacement: nil))
        #expect(frame.payload == ChromiumHostTextInputBytes.utf16LE("😀") + ChromiumHostTextInputBytes.clauses(clauses))
        #expect(ChromiumHostTextInputBytes.clauses(clauses) == [0, 0, 0, 0, 1, 0, 0, 0, 0x33, 0x22, 0x11, 0xFF, 0, 0, 0, 0])
    }

    /// The page views cmux makes in host mode send their input method ops to the host's IME
    /// exports: the pane's for its shown tab's browser, the DevTools page's for the DevTools
    /// browser. A host whose shim lacks them gets none.
    @Test(arguments: [true, false])
    func hostModePageViewsSendTheirOpsToTheHostsIMEExports(hostHasIME: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "cef-host-ime-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let shim = try CEFShimLibrary.resolving(IMESpy.symbol, hostExports: hostHasIME ? Self.imeExports : [])
        let runtime = CEFRuntime(shim: shim, storage: CEFProfileStorage(root: root))
        let hostStart = try await HostRepliesHarness.attachedHost(over: { IMESpy.symbol($0) })
        hostStart.mapsClientIDs = true
        runtime.hostStart = hostStart
        // A pane's scheduled work reads the runtime through an unowned reference.
        _ = Unmanaged.passRetained(runtime)
        let host = CEFPaneHost(key: CEFPaneKey(pane: BrowserPaneID(rawValue: UUID().uuidString), profile: .default), runtime: runtime)
        host.endOfTurn = { $0() }
        let tab = CEFTab(id: .random(), profile: .default, host: host, runtime: runtime)
        host.add(tab)
        host.ensureCreated(tab)
        let request = try #require(runtime.pendingWindows.keys.first { runtime.pendingWindows[$0] === host })
        runtime.handle(.afterCreated(browser: 7, request: request, window: 1))
        host.present(tab, in: NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300)))
        let page = try #require(host.hostedPageView)
        #expect(page.textInputSink != nil)
        IMESpy.calls.withLock { $0 = [] }

        page.applyTextInputState(Self.field)
        page.setMarkedText("に", selectedRange: NSRange(location: 1, length: 0),
                           replacementRange: NSRange(location: NSNotFound, length: 0))
        page.insertText("に", replacementRange: NSRange(location: NSNotFound, length: 0))

        let controller = tab.devToolsController
        let devTools = controller.hostedPage(for: tab)
        devTools.applyTextInputState(Self.field)
        devTools.insertText("a", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(IMESpy.calls.withLock { $0.count } == (hostHasIME ? 2 : 0), "an op went with no DevTools open")
        controller.devToolsBrowserID = 9
        devTools.insertText("a", replacementRange: NSRange(location: NSNotFound, length: 0))

        let text = ChromiumHostTextInputBytes.utf16LE("に")
        let clauses = ChromiumHostTextInputBytes.clauses([ChromiumHostCompositionClause(range: 0..<1, thick: false)])
        let expected: [IMESpy.Call] = hostHasIME ? [
            .set(browser: 7, text: text, clauses: clauses, selection: [1, 1], replace: [-1, -1]),
            .commit(browser: 7, text: text, replace: [-1, -1]),
            .commit(browser: 9, text: ChromiumHostTextInputBytes.utf16LE("a"), replace: [-1, -1]),
        ] : []
        #expect(IMESpy.calls.withLock { $0 } == expected)
    }

    /// A host whose hello does not list the fork's IME exports: cmux binds none and sends no op.
    @Test func aHostWithoutTheIMEExportsTakesNoOp() throws {
        let shim = try CEFShimLibrary.resolving(IMESpy.symbol, hostExports: [])
        #expect(shim.textInput.setComposition == nil && shim.textInput.commitText == nil)
        #expect(!shim.textInput.isComplete)
        #expect(!shim.textInput.send(.commitText("a", replacement: nil), browser: 7))
        #expect(!shim.textInput.send(.cancelComposition, browser: 7))
    }
}

/// A host shim whose IME exports record what they got and whose `create_window` makes a window
/// (1); every other export answers 0.
private nonisolated enum IMESpy {
    enum Call: Equatable, Sendable {
        case set(browser: Int32, text: [UInt8], clauses: [UInt8], selection: [Int32], replace: [Int32])
        case commit(browser: Int32, text: [UInt8], replace: [Int32])
        case finish(browser: Int32)
        case cancel(browser: Int32)
    }

    static let calls = Mutex<[Call]>([])

    static func bytes(_ pointer: UnsafePointer<UInt8>?, _ count: Int32) -> [UInt8] {
        // SAFETY: the caller passes its array's pointer and count, valid for the call.
        unsafe Array(UnsafeBufferPointer(start: pointer, count: Int(count)))
    }

    static func symbol(_ name: String) -> UnsafeMutableRawPointer? {
        let set: @convention(c) (Int32, UnsafePointer<UInt8>?, Int32, UnsafePointer<UInt8>?, Int32, Int32, Int32, Int32,
                                 Int32) -> Void = { browser, text, textCount, clauses, clauseCount, start, end, from, to in
            let call = Call.set(browser: browser, text: IMESpy.bytes(text, textCount), clauses: IMESpy.bytes(clauses, clauseCount),
                                selection: [start, end], replace: [from, to])
            IMESpy.calls.withLock { $0.append(call) }
        }
        let commit: @convention(c) (Int32, UnsafePointer<UInt8>?, Int32, Int32, Int32) -> Void = { browser, text, count, from, to in
            let call = Call.commit(browser: browser, text: IMESpy.bytes(text, count), replace: [from, to])
            IMESpy.calls.withLock { $0.append(call) }
        }
        let finish: @convention(c) (Int32) -> Void = { browser in IMESpy.calls.withLock { $0.append(.finish(browser: browser)) } }
        let cancel: @convention(c) (Int32) -> Void = { browser in IMESpy.calls.withLock { $0.append(.cancel(browser: browser)) } }
        let createWindow: @convention(c) (Int32, UnsafeMutableRawPointer?, Int32, Int32, UnsafePointer<CChar>?,
                                          UnsafePointer<CChar>?) -> Int32 = { _, _, _, _, _, _ in 1 }
        let nothing: @convention(c) () -> Int = { 0 }
        return switch name {
        case "cmux_shim_create_window": unsafeBitCast(createWindow, to: UnsafeMutableRawPointer.self)
        case "cmux_shim_browser_ime_set_composition": unsafeBitCast(set, to: UnsafeMutableRawPointer.self)
        case "cmux_shim_browser_ime_commit_text": unsafeBitCast(commit, to: UnsafeMutableRawPointer.self)
        case "cmux_shim_browser_ime_finish_composing": unsafeBitCast(finish, to: UnsafeMutableRawPointer.self)
        case "cmux_shim_browser_ime_cancel_composition": unsafeBitCast(cancel, to: UnsafeMutableRawPointer.self)
        default: unsafeBitCast(nothing, to: UnsafeMutableRawPointer.self)
        }
    }
}
#endif
