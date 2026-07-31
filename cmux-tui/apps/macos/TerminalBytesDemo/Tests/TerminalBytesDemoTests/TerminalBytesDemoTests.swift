import AppKit
import XCTest
@testable import TerminalBytesDemo

private final class PasteMenuItem: NSObject, NSValidatedUserInterfaceItem {
    let action: Selector? = #selector(NSText.paste(_:))
    let tag = 0
}

final class TerminalBytesDemoTests: XCTestCase {
    func testDemoConfigurationUsesOnlyExplicitEnvironment() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let invitation = directory.appendingPathComponent("invitation.txt")
        try "cmux://enroll/fresh\n".write(to: invitation, atomically: true, encoding: .utf8)

        let configuration = DemoLaunchConfiguration.processEnvironment([
            "CMUX_TERMINAL_INVITATION_FILE": invitation.path,
            "CMUX_TERMINAL_SURFACE": "73",
            "CMUX_TERMINAL_AUTOCONNECT": "1",
        ])

        XCTAssertEqual(
            configuration,
            DemoLaunchConfiguration(
                invitation: "cmux://enroll/fresh",
                surface: "73",
                autoConnect: true
            )
        )
    }

    func testGeometryClampsToValidTerminalCells() {
        XCTAssertEqual(
            terminalGeometry(width: 0, height: 0),
            TerminalGeometry(cols: 1, rows: 1)
        )
        XCTAssertEqual(
            terminalGeometry(width: 840, height: 340),
            TerminalGeometry(cols: 100, rows: 20)
        )
    }

    func testCStringCopyRetriesWhenValueGrowsBetweenPasses() {
        var calls = 0
        let value = copyGrowingCString { buffer, capacity in
            calls += 1
            let bytes = Array((calls == 1 ? "old" : "new-日本語").utf8)
            if let buffer, capacity > 0 {
                let copied = min(bytes.count, capacity - 1)
                for index in 0..<copied {
                    buffer[index] = CChar(bitPattern: bytes[index])
                }
                buffer[copied] = 0
            }
            return bytes.count
        }
        XCTAssertEqual(value, "new-日本語")
        XCTAssertGreaterThanOrEqual(calls, 3)
    }

    @MainActor
    func testNonEditableTerminalRoutesCommittedUnicodeAndPaste() throws {
        let terminal = TerminalTextView()
        terminal.configureForTerminal()
        var delivered: [TerminalInput] = []
        terminal.submit = { delivered.append($0) }
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
        let commandV = try XCTUnwrap(NSEvent.keyEvent(
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

        XCTAssertEqual(delivered, [
            .bytes(Data("日本語-e\u{301}".utf8)),
            .paste("貼り付け"),
        ])
        XCTAssertEqual(terminal.string, "")

        terminal.pasteboardText = { nil }
        XCTAssertFalse(terminal.validateUserInterfaceItem(PasteMenuItem()))
        XCTAssertFalse(terminal.performKeyEquivalent(with: commandV))
    }

    @MainActor
    func testTerminalClientHandleDisconnectsExactlyOnce() throws {
        let raw = try XCTUnwrap(OpaquePointer(bitPattern: 1))
        var disconnected: [OpaquePointer] = []
        let handle = TerminalClientHandle(raw: raw) {
            disconnected.append($0)
        }

        XCTAssertEqual(handle.withRaw { $0 }, raw)
        handle.disconnect()
        handle.disconnect()

        XCTAssertNil(handle.withRaw { $0 })
        XCTAssertEqual(disconnected, [raw])
    }

    @MainActor
    func testClosingLastWindowTerminatesDemoApp() {
        XCTAssertTrue(
            TerminalBytesDemoAppDelegate()
                .applicationShouldTerminateAfterLastWindowClosed(.shared)
        )
    }
}
