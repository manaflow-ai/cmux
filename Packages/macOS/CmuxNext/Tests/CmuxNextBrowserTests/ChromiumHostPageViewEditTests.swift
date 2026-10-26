#if DEBUG
// The Chromium host app ships in Debug builds only (embed-cef.sh), and so does its Swift side.
import AppKit
@testable import CmuxNextBrowser
import Testing

/// The hosted page's Edit menu, Services, Start Speaking, Look Up and dictation (p01-process-047):
/// Edit menu actions become Blink edit commands, and everything that reads the page's text reads
/// the selection the host pushed, asking the host nothing.
@MainActor
@Suite struct ChromiumHostPageViewEditTests {
    /// A text field holding "hello world" with "world" selected (offsets 6..<11), its first line at (40, 10).
    static let selected = ChromiumHostTextInputState(type: .text, selection: 6..<11, text: "hello world", textOffset: 0,
                                                     caretRect: CGRect(x: 40, y: 10, width: 30, height: 16))

    @MainActor
    final class SpeechRecorder: ChromiumHostSpeaking {
        var spoken: [String] = []
        var stops = 0
        var isSpeaking = false
        func speak(_ text: String) {
            spoken.append(text)
            isSpeaking = true
        }
        func stopSpeaking() {
            stops += 1
            isSpeaking = false
        }
    }

    func makePage() -> (ChromiumHostPageView, NSWindow) {
        _ = NSApplication.shared
        let page = ChromiumHostPageView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), inputTarget: .view,
                                        makeLayerHost: { _ in CALayer() }, pageUpdateCenter: NotificationCenter())
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 400, height: 300), styleMask: .borderless,
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(page)
        return (page, window)
    }

    // MARK: Edit menu

    @Test func editMenuActionsSendBlinkEditCommands() {
        let (page, window) = makePage()
        defer { window.close() }
        var sent: [ChromiumHostEditCommand] = []
        page.editCommandSink = { sent.append($0) }
        page.undo(nil)
        page.redo(nil)
        page.cut(nil)
        page.copy(nil)
        page.paste(nil)
        page.pasteAsPlainText(nil)
        page.pasteAndMatchStyle(nil)
        page.delete(nil)
        page.selectAll(nil)
        #expect(sent == [.undo, .redo, .cut, .copy, .paste, .pasteAndMatchStyle, .pasteAndMatchStyle, .delete, .selectAll])
        #expect(sent.map(\.rawValue) == ["Undo", "Redo", "Cut", "Copy", "Paste", "PasteAndMatchStyle",
                                         "PasteAndMatchStyle", "Delete", "SelectAll"])
    }

    /// cmux's own Edit menu items reach the page view through the responder chain.
    @Test func theMainMenuSelectorsReachThePageView() {
        let (page, window) = makePage()
        defer { window.close() }
        for action in [#selector(NSText.copy(_:)), #selector(NSText.cut(_:)), #selector(NSText.paste(_:)),
                       #selector(NSTextView.pasteAsPlainText(_:)), #selector(NSText.selectAll(_:)),
                       Selector(("undo:")), Selector(("redo:"))] {
            #expect(page.responds(to: action), "\(action)")
        }
    }

    /// A hosted widget takes its commands as kEdit frames; commands that frame has no code for stay away.
    @Test func editFramesKeepTheirWireCodes() {
        let codes: [Int32?] = ChromiumHostEditCommand.allCases.map { $0.editFrame?.v[0] }
        #expect(codes == [4, 5, 1, 0, 2, nil, nil, 3])
        #expect(ChromiumHostEditCommand.copy.editFrame?.kind == .edit)
    }

    /// The session's wire: an Edit menu command is kIme's edit command with no key (op 5).
    @Test func anEditCommandIsKimeOpFiveOnTheSessionWire() {
        let frame = ChromiumHostFrame(textInput: .editCommand(ChromiumHostEditCommand.paste.rawValue))
        #expect(frame.kind == .ime)
        #expect(frame.v[0] == 5)
        #expect(frame.payload == Array("Paste".utf16).flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] })
    }

    // MARK: Pushed selection

    @Test func theSelectedTextComesFromThePush() {
        let (page, window) = makePage()
        defer { window.close() }
        #expect(page.selectedPageText == nil)
        page.applyTextInputState(Self.selected)
        #expect(page.selectedPageText == "world")
        // A caret selects nothing.
        page.applyTextInputState(ChromiumHostTextInputState(type: .text, selection: 3..<3, text: "hello world"))
        #expect(page.selectedPageText == nil)
        // A selection longer than the text the host sent: none, rather than part of it.
        page.applyTextInputState(ChromiumHostTextInputState(type: .text, selection: 6..<40, text: "hello world"))
        #expect(page.selectedPageText == nil)
        // Never a password.
        page.applyTextInputState(ChromiumHostTextInputState(type: .password, selection: 0..<5, text: "hunter2"))
        #expect(page.selectedPageText == nil)
    }

    // MARK: Speech

    @Test func startSpeakingSpeaksThePushedSelectionInCmux() {
        let (page, window) = makePage()
        defer { window.close() }
        let speech = SpeechRecorder()
        page.speech = speech
        let start = NSMenuItem(title: "Start Speaking", action: #selector(ChromiumHostPageView.startSpeaking(_:)),
                               keyEquivalent: "")
        let stop = NSMenuItem(title: "Stop Speaking", action: #selector(ChromiumHostPageView.stopSpeaking(_:)),
                              keyEquivalent: "")
        #expect(!page.validateMenuItem(start))
        page.startSpeaking(nil)
        #expect(speech.spoken.isEmpty)

        page.applyTextInputState(Self.selected)
        #expect(page.validateMenuItem(start))
        #expect(!page.validateMenuItem(stop))
        page.startSpeaking(nil)
        #expect(speech.spoken == ["world"])
        #expect(page.validateMenuItem(stop))
        page.stopSpeaking(nil)
        #expect(speech.stops == 1)
        #expect(!page.validateMenuItem(stop))
        let copy = NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        #expect(page.validateMenuItem(copy))
    }

    // MARK: Services

    @Test func servicesTakeTheSelectionAndReturnTextToTheField() {
        let (page, window) = makePage()
        defer { window.close() }
        func requests(_ send: NSPasteboard.PasteboardType?, _ back: NSPasteboard.PasteboardType?) -> Bool {
            (page.validRequestor(forSendType: send, returnType: back) as AnyObject?) === page
        }
        // No field, no selection: not a requestor.
        #expect(!requests(.string, nil))
        #expect(!requests(nil, .string))

        page.applyTextInputState(Self.selected)
        #expect(requests(.string, nil))
        #expect(requests(nil, .string))
        #expect(requests(.string, .string))
        #expect(!requests(.tiff, nil))

        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        #expect(page.writeSelection(to: pasteboard, types: [.string]))
        #expect(pasteboard.string(forType: .string) == "world")
        #expect(!page.writeSelection(to: pasteboard, types: [.tiff]))
    }

    @Test func aServicesReplyCommitsAfterTheCompositionEnds() {
        let (page, window) = makePage()
        defer { window.close() }
        var ops: [ChromiumHostTextInputOp] = []
        page.textInputSink = { ops.append($0) }
        page.applyTextInputState(Self.selected)
        page.setMarkedText("か", selectedRange: NSRange(location: 1, length: 0),
                           replacementRange: NSRange(location: NSNotFound, length: 0))
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("WORLD", forType: .string)
        #expect(page.readSelection(from: pasteboard))
        #expect(Array(ops.dropFirst()) == [.finishComposing, .commitText("WORLD", replacement: nil)])
        #expect(!page.hasMarkedText())
    }

    // MARK: Dictation

    /// Dictation inserts with no key down: the text commits at once.
    @Test func dictationInsertsText() {
        let (page, window) = makePage()
        defer { window.close() }
        var ops: [ChromiumHostTextInputOp] = []
        page.textInputSink = { ops.append($0) }
        page.applyTextInputState(Self.selected)
        page.insertText("dictated words", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(ops == [.commitText("dictated words", replacement: nil)])
    }

    // MARK: Look Up

    @Test func lookUpNeedsAPushedSelection() {
        let (page, window) = makePage()
        defer { window.close() }
        #expect(!page.showDefinitionForSelection())
    }
}
#endif
