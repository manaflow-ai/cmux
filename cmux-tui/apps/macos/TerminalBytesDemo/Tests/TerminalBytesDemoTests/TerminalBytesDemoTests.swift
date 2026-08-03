import AppKit
import XCTest

@testable import TerminalBytesDemo

private final class PasteMenuItem: NSObject, NSValidatedUserInterfaceItem {
    let action: Selector? = #selector(NSText.paste(_:))
    let tag = 0
}

final class TerminalBytesDemoTests: XCTestCase {
    @MainActor
    func testNonEditableTerminalRoutesCommittedUnicodeAndPaste() throws {
        let terminal = TerminalTextView()
        terminal.configureForTerminal()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = terminal
        XCTAssertTrue(window.makeFirstResponder(terminal))
        XCTAssertTrue(window.firstResponder === terminal)

        var delivered: [TerminalInput] = []
        terminal.submit = {
            delivered.append($0)
        }
        terminal.isInputReady = true
        terminal.pasteboardText = { "貼り付け" }

        XCTAssertFalse(terminal.isEditable)
        XCTAssertTrue(terminal.isSelectable)
        XCTAssertTrue(terminal.validateUserInterfaceItem(PasteMenuItem()))
        terminal.string = "server frame"
        XCTAssertEqual(terminal.string, "server frame")
        terminal.string = ""

        terminal.insertText(
            NSAttributedString(string: "日本語-e\u{301}"),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        let commandV = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: .command,
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: "v",
                charactersIgnoringModifiers: "v",
                isARepeat: false,
                keyCode: 9
            ))
        XCTAssertTrue(terminal.performKeyEquivalent(with: commandV))
        terminal.paste(nil)

        XCTAssertEqual(
            delivered,
            [
                .bytes(Data("日本語-e\u{301}".utf8)),
                .paste("貼り付け"),
                .paste("貼り付け"),
            ])
        XCTAssertEqual(terminal.string, "")

        terminal.pasteboardText = { nil }
        XCTAssertFalse(terminal.validateUserInterfaceItem(PasteMenuItem()))
        XCTAssertFalse(terminal.performKeyEquivalent(with: commandV))

        terminal.pasteboardText = { "must remain available" }
        terminal.submit = nil
        XCTAssertFalse(terminal.validateUserInterfaceItem(PasteMenuItem()))
        XCTAssertFalse(terminal.performKeyEquivalent(with: commandV))
    }

    @MainActor
    func testTerminalDoesNotInterceptCommandVFromAnotherFirstResponder() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let content = NSView(frame: window.contentLayoutRect)
        let terminal = TerminalTextView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        terminal.configureForTerminal()
        let textField = NSTextField(frame: NSRect(x: 0, y: 420, width: 640, height: 24))
        content.addSubview(terminal)
        content.addSubview(textField)
        window.contentView = content

        var delivered: [TerminalInput] = []
        terminal.submit = {
            delivered.append($0)
        }
        terminal.isInputReady = true
        terminal.pasteboardText = { "must stay in the field" }
        XCTAssertTrue(window.makeFirstResponder(textField))
        XCTAssertFalse(window.firstResponder === terminal)

        let commandV = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: .command,
                timestamp: 0,
                windowNumber: window.windowNumber,
                context: nil,
                characters: "v",
                charactersIgnoringModifiers: "v",
                isARepeat: false,
                keyCode: 9
            ))
        XCTAssertFalse(terminal.performKeyEquivalent(with: commandV))
        XCTAssertTrue(delivered.isEmpty)
    }

    @MainActor
    func testClosingLastWindowTerminatesDemoApp() {
        XCTAssertTrue(
            TerminalBytesDemoAppDelegate()
                .applicationShouldTerminateAfterLastWindowClosed(.shared)
        )
    }
}
