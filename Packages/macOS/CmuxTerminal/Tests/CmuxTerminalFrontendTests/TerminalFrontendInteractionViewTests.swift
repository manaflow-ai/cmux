import AppKit
@testable import CmuxTerminalFrontend
import Foundation
import Testing

@MainActor
@Suite struct TerminalFrontendInteractionViewTests {
    @Test func physicalKeyPressRepeatAndReleaseKeepOneSemanticKeyPath() throws {
        let runtime = FakeTerminalExternalRuntime()
        let view = TerminalFrontendInteractionView(
            frame: NSRect(x: 0, y: 0, width: 400, height: 200),
            runtime: runtime,
            surfaceView: TerminalFrontendSurfaceView(frame: .zero),
            keyEventInterpreter: { client, _ in
                client.insertText(
                    "a",
                    replacementRange: NSRange(location: NSNotFound, length: 0)
                )
            }
        )
        let press = try makeKeyEvent(type: .keyDown, characters: "a", keyCode: 0)
        let repeatEvent = try makeKeyEvent(
            type: .keyDown,
            characters: "a",
            isARepeat: true,
            keyCode: 0
        )
        let release = try makeKeyEvent(type: .keyUp, characters: "a", keyCode: 0)

        view.keyDown(with: press)
        view.keyDown(with: repeatEvent)
        view.keyUp(with: release)

        #expect(runtime.mutations == [
            .input(.key(TerminalExternalKeyEvent(
                key: TerminalW3CKey.keyA.rawValue,
                text: "a",
                unshiftedCodepoint: 0x61,
                action: .press
            ))),
            .input(.key(TerminalExternalKeyEvent(
                key: TerminalW3CKey.keyA.rawValue,
                text: "a",
                unshiftedCodepoint: 0x61,
                action: .repeat
            ))),
            .input(.key(TerminalExternalKeyEvent(
                key: TerminalW3CKey.keyA.rawValue,
                unshiftedCodepoint: 0x61,
                action: .release
            ))),
        ])
    }

    @Test func flagsChangedPreservesModifierSideAndAction() throws {
        let runtime = FakeTerminalExternalRuntime()
        let view = TerminalFrontendInteractionView(runtime: runtime)
        let downFlags = NSEvent.ModifierFlags(
            rawValue: NSEvent.ModifierFlags.shift.rawValue
                | UInt(NX_DEVICERSHIFTKEYMASK)
        )
        let down = try makeKeyEvent(
            type: .flagsChanged,
            modifierFlags: downFlags,
            characters: "",
            keyCode: 60
        )
        let up = try makeKeyEvent(
            type: .flagsChanged,
            characters: "",
            keyCode: 60
        )

        view.flagsChanged(with: down)
        view.flagsChanged(with: up)

        #expect(runtime.mutations == [
            .input(.key(TerminalExternalKeyEvent(
                key: TerminalW3CKey.shiftRight.rawValue,
                modifiers: [.shift, .rightShift],
                action: .press
            ))),
            .input(.key(TerminalExternalKeyEvent(
                key: TerminalW3CKey.shiftRight.rawValue,
                action: .release
            ))),
        ])
    }

    @Test func directCommittedTextSplitsControlsWithoutDuplicatingCRLF() {
        let runtime = FakeTerminalExternalRuntime()
        let view = TerminalFrontendInteractionView(runtime: runtime)

        view.insertText(
            NSAttributedString(string: "a\r\nb\t\u{1B}c"),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )

        #expect(runtime.mutations == [
            .input(.text(TerminalExternalTextInput(text: "a", kind: .committed))),
            .input(.namedKey("enter")),
            .input(.text(TerminalExternalTextInput(text: "b", kind: .committed))),
            .input(.namedKey("tab")),
            .input(.namedKey("escape")),
            .input(.text(TerminalExternalTextInput(text: "c", kind: .committed))),
        ])
    }

    @Test func markedTextUsesUTF16RangesAndUnmarkClearsPreedit() throws {
        let runtime = FakeTerminalExternalRuntime()
        let view = TerminalFrontendInteractionView(runtime: runtime)

        view.setMarkedText(
            "a😀",
            selectedRange: NSRange(location: 1, length: 2),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        var actualRange = NSRange(location: NSNotFound, length: 0)
        let substring = view.attributedSubstring(
            forProposedRange: NSRange(location: 1, length: 2),
            actualRange: &actualRange
        )

        #expect(view.hasMarkedText())
        #expect(view.markedRange() == NSRange(location: 0, length: 3))
        #expect(view.selectedRange() == NSRange(location: 1, length: 2))
        #expect(substring?.string == "😀")
        #expect(actualRange == NSRange(location: 1, length: 2))
        #expect(runtime.mutations == [
            .preedit(TerminalExternalPreedit(
                text: "a😀",
                selectionStartUTF16: 1,
                selectionLengthUTF16: 2,
                caretUTF16: 3
            )),
        ])

        view.unmarkText()

        #expect(!view.hasMarkedText())
        #expect(view.markedRange() == NSRange(location: NSNotFound, length: 0))
        #expect(runtime.mutations.last == .preedit(nil))
    }

    @Test func markedTextStorageHasAFixedUTF16Ceiling() {
        let runtime = FakeTerminalExternalRuntime()
        let view = TerminalFrontendInteractionView(runtime: runtime)
        let oversized = String(
            repeating: "x",
            count: TerminalFrontendInteractionView.maximumMarkedTextUTF16Length + 17
        )

        view.setMarkedText(
            oversized,
            selectedRange: NSRange(location: oversized.utf16.count, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )

        #expect(
            view.markedRange().length
                == TerminalFrontendInteractionView.maximumMarkedTextUTF16Length
        )
        guard case .preedit(let preedit?) = runtime.mutations.last else {
            Issue.record("Expected a bounded preedit mutation")
            return
        }
        #expect(
            preedit.text.utf16.count
                == TerminalFrontendInteractionView.maximumMarkedTextUTF16Length
        )
        #expect(
            preedit.caretUTF16
                == UInt32(TerminalFrontendInteractionView.maximumMarkedTextUTF16Length)
        )
    }

    @Test func IMECompositionOwnsTheKeyAndSuppressesItsRelease() throws {
        let runtime = FakeTerminalExternalRuntime()
        let view = TerminalFrontendInteractionView(
            frame: .zero,
            runtime: runtime,
            surfaceView: TerminalFrontendSurfaceView(frame: .zero),
            keyEventInterpreter: { client, _ in
                client.insertText(
                    "日",
                    replacementRange: NSRange(location: NSNotFound, length: 0)
                )
            }
        )
        view.setMarkedText(
            "に",
            selectedRange: NSRange(location: 1, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        let press = try makeKeyEvent(type: .keyDown, characters: "j", keyCode: 38)
        let release = try makeKeyEvent(type: .keyUp, characters: "j", keyCode: 38)

        view.keyDown(with: press)
        view.keyUp(with: release)

        #expect(runtime.mutations == [
            .preedit(TerminalExternalPreedit.collapsedAtEnd("に")),
            .preedit(nil),
            .input(.text(TerminalExternalTextInput(text: "日", kind: .committed))),
        ])
        #expect(!runtime.mutations.contains { mutation in
            guard case .input(.key) = mutation else { return false }
            return true
        })
    }

    @Test func viewOwnsResponderFocusAndLeavesPixelsAsAChild() throws {
        let runtime = FakeTerminalExternalRuntime()
        let surfaceView = TerminalFrontendSurfaceView(frame: .zero)
        let view = TerminalFrontendInteractionView(
            frame: NSRect(x: 0, y: 0, width: 400, height: 200),
            runtime: runtime,
            surfaceView: surfaceView
        )
        let window = NSWindow(
            contentRect: view.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.contentView = view

        #expect(view.acceptsFirstResponder)
        #expect(view.hitTest(NSPoint(x: 10, y: 10)) === view)
        #expect(surfaceView.superview === view)
        #expect(surfaceView.frame == view.bounds)
        #expect(window.makeFirstResponder(view))
        #expect(window.firstResponder === view)
        #expect(window.makeFirstResponder(nil))
        #expect(runtime.mutations == [.focus(true), .focus(false)])
    }

    @Test func firstRectUsesCursorViewportCellMetricsAndScreenCoordinates() {
        let runtime = FakeTerminalExternalRuntime()
        runtime.snapshot = TerminalExternalRuntimeSnapshot(
            lifecycle: .live,
            cellMetrics: TerminalExternalCellMetrics(
                columns: 10,
                rows: 5,
                cellWidthPixels: 20,
                cellHeightPixels: 40,
                surfaceWidthPixels: 200,
                surfaceHeightPixels: 200,
                backingScale: 2
            ),
            cursor: TerminalExternalCursorState(column: 3, row: 101, visible: true),
            viewportState: TerminalExternalViewportState(
                totalRows: 200,
                offset: 100,
                visibleRows: 5
            )
        )
        let view = TerminalFrontendInteractionView(
            frame: NSRect(x: 0, y: 0, width: 400, height: 200),
            runtime: runtime
        )
        let window = NSWindow(
            contentRect: view.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.setFrameOrigin(NSPoint(x: 100, y: 300))
        window.contentView = view
        let localCellRect = NSRect(x: 180, y: 110, width: 10, height: 20)

        let boxRect = view.firstRect(
            forCharacterRange: NSRange(location: 0, length: 1),
            actualRange: nil
        )
        let caretRect = view.firstRect(
            forCharacterRange: NSRange(location: 0, length: 0),
            actualRange: nil
        )
        let expectedBox = window.convertToScreen(view.convert(localCellRect, to: nil))

        #expect(boxRect == expectedBox)
        #expect(caretRect.origin == expectedBox.origin)
        #expect(caretRect.width == 0)
        #expect(caretRect.height == expectedBox.height)
    }

    @Test func rejectedPressIsNotRetriedAndCannotEmitAnOrphanRelease() throws {
        let runtime = FakeTerminalExternalRuntime()
        runtime.stubbedIngressResults = [.rejected(.queueFull)]
        let view = TerminalFrontendInteractionView(
            frame: .zero,
            runtime: runtime,
            surfaceView: TerminalFrontendSurfaceView(frame: .zero),
            keyEventInterpreter: { _, _ in }
        )
        let press = try makeKeyEvent(type: .keyDown, characters: "a", keyCode: 0)
        let release = try makeKeyEvent(type: .keyUp, characters: "a", keyCode: 0)

        view.keyDown(with: press)
        view.keyUp(with: release)

        #expect(runtime.mutations.count == 1)
        #expect(view.lastIngressResult == .rejected(.queueFull))
        guard case .input(.key(let key)) = runtime.mutations.first else {
            Issue.record("Expected one rejected key press")
            return
        }
        #expect(key.action == .press)
    }

    @Test func interactionHostSourceDoesNotImportLegacyTerminalOrGhosttyModules() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = packageRoot
            .appendingPathComponent("Sources/CmuxTerminalFrontend/Hosting")
            .appendingPathComponent("TerminalFrontendInteractionView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let importedModules = source.split(separator: "\n").compactMap { line -> String? in
            let tokens = line.split(whereSeparator: \.isWhitespace)
            guard let importIndex = tokens.firstIndex(of: "import") else { return nil }
            let moduleIndex = tokens.index(after: importIndex)
            guard moduleIndex < tokens.endIndex else { return nil }
            return String(tokens[moduleIndex])
        }

        #expect(!importedModules.contains("CmuxTerminal"))
        #expect(!importedModules.contains { $0.hasPrefix("Ghostty") })
    }

    private func makeKeyEvent(
        type: NSEvent.EventType,
        modifierFlags: NSEvent.ModifierFlags = [],
        characters: String,
        isARepeat: Bool = false,
        keyCode: UInt16
    ) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: type,
            location: .zero,
            modifierFlags: modifierFlags,
            timestamp: 1,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: isARepeat,
            keyCode: keyCode
        ))
    }
}
