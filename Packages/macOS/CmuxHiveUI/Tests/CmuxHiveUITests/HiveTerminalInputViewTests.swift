import AppKit
import Testing
@testable import CmuxHiveUI

@MainActor
@Suite(.serialized)
struct HiveTerminalInputViewTests {
    @Test func markedJapaneseTextSendsOnlyTheCommittedText() {
        let view = HiveTerminalKeyCaptureNSView()
        var sent: [String] = []
        view.actions = .init(
            sendText: { sent.append($0) },
            sendSpecial: { _, _ in },
            sendControl: { _ in }
        )
        view.setInputEnabled(true)

        view.setMarkedText(
            "にほんご",
            selectedRange: NSRange(location: 4, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        #expect(view.hasMarkedText())
        #expect(view.markedRange() == NSRange(location: 0, length: 4))
        #expect(sent.isEmpty)

        view.insertText(
            NSAttributedString(string: "日本語"),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        #expect(sent == ["日本語"])
        #expect(!view.hasMarkedText())
    }

    @Test func disablingInputClearsCompositionAndSuppressesLateCommits() {
        let view = HiveTerminalKeyCaptureNSView()
        var sent: [String] = []
        view.actions = .init(
            sendText: { sent.append($0) },
            sendSpecial: { _, _ in },
            sendControl: { _ in }
        )
        view.setInputEnabled(true)
        view.setMarkedText(
            "かな",
            selectedRange: NSRange(location: 2, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )

        view.setInputEnabled(false)
        view.insertText("仮名", replacementRange: NSRange(location: NSNotFound, length: 0))

        #expect(!view.hasMarkedText())
        #expect(sent.isEmpty)
    }

    @Test func repeatedRenderUpdatesDoNotReclaimAnotherControlsFocus() throws {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let content = try #require(window.contentView)
        let terminal = HiveTerminalKeyCaptureNSView()
        let otherControl = HiveTerminalKeyCaptureNSView()
        content.addSubview(terminal)
        content.addSubview(otherControl)

        terminal.setInputEnabled(true)
        #expect(window.firstResponder === terminal)
        try #require(window.makeFirstResponder(otherControl))
        try #require(window.firstResponder === otherControl)

        terminal.setInputEnabled(true)
        terminal.setInputEnabled(true)

        #expect(window.firstResponder === otherControl)
    }
}
