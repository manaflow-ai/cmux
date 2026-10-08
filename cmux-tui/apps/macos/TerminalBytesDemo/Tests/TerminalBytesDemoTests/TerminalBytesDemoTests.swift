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
        terminal.insertText(
            "discarded while disconnected",
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        XCTAssertTrue(delivered.isEmpty)
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
    func testMarkedTextOwnsNamedKeysUntilIMECommit() throws {
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

        var delivered: [TerminalInput] = []
        terminal.submit = { delivered.append($0) }
        terminal.isInputReady = true
        terminal.string = "prompt> "
        terminal.setSelectedRange(NSRange(location: 8, length: 0))
        terminal.setMarkedText(
            "かな",
            selectedRange: NSRange(location: 2, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        XCTAssertTrue(terminal.hasMarkedText())
        XCTAssertEqual(terminal.string, "prompt> かな")
        XCTAssertEqual(terminal.markedRange(), NSRange(location: 8, length: 2))
        XCTAssertEqual(terminal.selectedRange(), NSRange(location: 10, length: 0))

        let backspace = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: window.windowNumber,
                context: nil,
                characters: "\u{7f}",
                charactersIgnoringModifiers: "\u{7f}",
                isARepeat: false,
                keyCode: 51
            ))
        terminal.keyDown(with: backspace)

        XCTAssertTrue(delivered.isEmpty)
        terminal.applyTerminalFrame("prompt> output")
        XCTAssertEqual(terminal.terminalFrameText, "prompt> output")
        XCTAssertEqual(terminal.string, "prompt> outputかな")
        XCTAssertEqual(terminal.markedRange(), NSRange(location: 14, length: 2))

        terminal.insertText(
            "仮名",
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        XCTAssertEqual(delivered, [.bytes(Data("仮名".utf8))])
        XCTAssertFalse(terminal.hasMarkedText())
        XCTAssertEqual(terminal.string, "prompt> output")
    }

    @MainActor
    func testDirtyRowsUpdateOnlyTheChangedViewportRows() {
        let terminal = TerminalTextView()
        terminal.configureForTerminal()
        terminal.applyTerminalFrame("first\nsecond\nthird\n")

        let edit = terminal.applyTerminalFrame(
            nil,
            dirtyRows: [1],
            dirtyRowText: [1: "changed\n"]
        )

        XCTAssertNotNil(edit)
        XCTAssertEqual(edit?.range, NSRange(location: 6, length: 7))
        XCTAssertEqual(edit?.replacement, "changed\n")
        XCTAssertEqual(terminal.string, "first\nchanged\nthird\n")
    }

    @MainActor
    func testFullDirtyRowsResetCachedTopologyWhenViewportShrinks() {
        let terminal = TerminalTextView()
        terminal.configureForTerminal()
        terminal.applyTerminalFrame("one\ntwo\nthree\n")

        terminal.applyTerminalFrame(
            nil,
            dirtyRows: [0, 1],
            dirtyRowText: [0: "one\n", 1: "two\n"],
            rowCount: 2
        )

        XCTAssertEqual(terminal.string, "one\ntwo\n")
    }

    @MainActor
    func testEmptyInitialFrameStillAcceptsTheFirstDirtyRow() {
        let terminal = TerminalTextView()
        terminal.configureForTerminal()
        terminal.applyTerminalFrame("")

        terminal.applyTerminalFrame(
            nil,
            dirtyRows: [0],
            dirtyRowText: [0: "output\n"],
            rowCount: 1
        )

        XCTAssertEqual(terminal.string, "output\n")
    }

    func testLauncherUsesAnInvocationOwnedSwiftBuildDirectory() throws {
        let demoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: demoRoot.appendingPathComponent("run-demo.sh"),
            encoding: .utf8
        )

        XCTAssertFalse(source.contains("swift-package clean"))
        XCTAssertTrue(source.contains("--scratch-path \"$SWIFT_BUILD_ROOT\""))
        XCTAssertFalse(source.contains("$SCRIPT_DIR/.build/debug"))
        XCTAssertTrue(source.contains("trap cleanup EXIT"))
        XCTAssertTrue(source.contains("trap 'exit 130' INT"))
        XCTAssertTrue(source.contains("trap 'exit 143' TERM"))
        XCTAssertFalse(source.contains("trap cleanup EXIT INT TERM"))
    }

    func testPackageLinksFrameworkRequiredByIrohInterfaceDiscovery() throws {
        let demoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let manifest = try String(
            contentsOf: demoRoot.appendingPathComponent("Package.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(manifest.contains(".linkedFramework(\"CoreWLAN\")"))
    }

    @MainActor
    func testClosingLastWindowTerminatesDemoApp() {
        XCTAssertTrue(
            TerminalBytesDemoAppDelegate()
                .applicationShouldTerminateAfterLastWindowClosed(.shared)
        )
    }
}
