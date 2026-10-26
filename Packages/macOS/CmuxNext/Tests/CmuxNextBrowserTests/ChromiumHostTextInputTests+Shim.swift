#if DEBUG
// The Chromium host app ships in Debug builds only (embed-cef.sh), and so does its text input.
import AppKit
@testable import CmuxNextBrowser
import CmuxNextCompat
import Testing

/// Host IME (p04-input-064): the page view's ops reach the host's shim as its IME exports, with
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

    /// A host whose hello does not list the fork's IME exports: cmux binds none and sends no op.
    @Test func aHostWithoutTheIMEExportsTakesNoOp() throws {
        let shim = try CEFShimLibrary.resolving(IMESpy.symbol, hostExports: [])
        #expect(shim.textInput.setComposition == nil && shim.textInput.commitText == nil)
        #expect(!shim.textInput.isComplete)
        #expect(!shim.textInput.send(.commitText("a", replacement: nil), browser: 7))
        #expect(!shim.textInput.send(.cancelComposition, browser: 7))
    }
}

/// A host shim whose IME exports record what they got; every other export answers 0.
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
        let nothing: @convention(c) () -> Int = { 0 }
        return switch name {
        case "cmux_shim_browser_ime_set_composition": unsafeBitCast(set, to: UnsafeMutableRawPointer.self)
        case "cmux_shim_browser_ime_commit_text": unsafeBitCast(commit, to: UnsafeMutableRawPointer.self)
        case "cmux_shim_browser_ime_finish_composing": unsafeBitCast(finish, to: UnsafeMutableRawPointer.self)
        case "cmux_shim_browser_ime_cancel_composition": unsafeBitCast(cancel, to: UnsafeMutableRawPointer.self)
        default: unsafeBitCast(nothing, to: UnsafeMutableRawPointer.self)
        }
    }
}
#endif
