import AppKit
@testable import CmuxHomeCore
import Foundation
import Testing
@testable import MessagesLabHome

/// Ctrl+A and Ctrl+E in Home's message box go to the start and the end of the caret's text line,
/// as in any macOS text field, also with a picture in the text (Lawrence 2026-10-28, scrawl
/// 1793232894245: "ctrl+a/ctrl+e should go to start and end of line; image is interfering with
/// it"). A picture is a block on its own line (`ComposeInlineAttachment`), but AppKit's Ctrl+A and
/// Ctrl+E (`moveToBeginningOfParagraph:` / `moveToEndOfParagraph:`) took the text before and after
/// it as one paragraph, so from the text under a picture Ctrl+A went above the picture.
///
/// Drives the real Home view over the mock owner (`HomeChatRig`) with the picture added through the
/// paste intake, and sends the commands AppKit's key bindings send for the keys.
@MainActor @Suite(.serialized) struct ComposerLineEdgeKeysTests {
    @MainActor struct Box {
        let rig: HomeChatRig
        let dir: URL
        var field: FieldTextView { rig.view.controller.demo!.compose.textView.view }

        func type(_ text: String) {
            if rig.window.firstResponder !== field { _ = rig.window.makeFirstResponder(field) }
            field.insertText(text, replacementRange: field.selectedRange())
            rig.frame()
        }

        /// A screenshot enters at the caret through the paste intake (`addDraftAttachment`).
        func paste() async throws {
            if rig.window.firstResponder !== field { _ = rig.window.makeFirstResponder(field) }
            let url = dir.appendingPathComponent("shot-\(UUID().uuidString).png")
            try ComposerInlineImageShotsTests.png(1412, 1106, hue: 0.58).write(to: url)
            let prepared = try await rig.store.prepareAttachment(fileURL: url)
            await rig.view.addDraftAttachment(prepared)
            if let s = field.textStorage {
                s.enumerateAttribute(.attachment, in: NSRange(location: 0, length: s.length)) { v, _, _ in
                    (v as? ComposeInlineAttachment)?.loadThumbnailNow(scale: 2)
                }
            }
            for _ in 0..<4 { rig.frame() }
            field.layoutSubtreeIfNeeded()
        }

        /// The command AppKit's standard key bindings send for a key (Ctrl+A, Ctrl+E, and with Shift).
        func send(_ selector: Selector) {
            field.doCommand(by: selector)
            rig.frame()
        }

        func caret(at location: Int) { field.setSelectedRange(NSRange(location: location, length: 0)) }
        var selection: NSRange { field.selectedRange() }
        var length: Int { (field.string as NSString).length }

        func stop() {
            rig.stop()
            try? FileManager.default.removeItem(at: dir)
        }
    }

    private func box() async throws -> Box {
        let rig = try await HomeChatRig(history: 0, width: 700)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("composer-line-edges-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        rig.frame()
        return Box(rig: rig, dir: dir)
    }

    static let home = #selector(NSResponder.moveToBeginningOfParagraph(_:))
    static let end = #selector(NSResponder.moveToEndOfParagraph(_:))
    static let homeExtending = #selector(NSResponder.moveToBeginningOfParagraphAndModifySelection(_:))
    static let endExtending = #selector(NSResponder.moveToEndOfParagraphAndModifySelection(_:))

    /// The scrawl's box: "hh", a screenshot, then the line under it. From the end of that line,
    /// Ctrl+A goes to its start (just after the picture), and Ctrl+E back to its end.
    @Test func underAPictureTheKeysStayOnTheLine() async throws {
        let b = try await box()
        defer { b.stop() }
        b.type("hh")
        try await b.paste()
        b.type("ighlighting full table cells is still weird")
        #expect(b.rig.view.draftText == "hh\u{FFFC}ighlighting full table cells is still weird")
        let lineStart = 3
        b.caret(at: b.length)
        b.send(Self.home)
        #expect(b.selection == NSRange(location: lineStart, length: 0), "Ctrl+A goes to the line's start, after the picture (\(b.selection))")
        b.send(Self.end)
        #expect(b.selection == NSRange(location: b.length, length: 0), "Ctrl+E goes to the line's end (\(b.selection))")
        b.caret(at: 10)
        b.send(Self.home)
        #expect(b.selection == NSRange(location: lineStart, length: 0), "from the middle too (\(b.selection))")
    }

    /// Above a picture: Ctrl+E stops at the end of the text, before the picture; Ctrl+A goes to the start.
    @Test func aboveAPictureTheKeysStayOnTheLine() async throws {
        let b = try await box()
        defer { b.stop() }
        b.type("hh")
        try await b.paste()
        b.type("after")
        b.caret(at: 1)
        b.send(Self.end)
        #expect(b.selection == NSRange(location: 2, length: 0), "Ctrl+E stops before the picture (\(b.selection))")
        b.send(Self.home)
        #expect(b.selection == NSRange(location: 0, length: 0), "Ctrl+A goes to the box's start (\(b.selection))")
    }

    /// Shift+Ctrl+A and Shift+Ctrl+E select to the line's edges, never the picture.
    @Test func shiftSelectsToTheLineEdgeOnly() async throws {
        let b = try await box()
        defer { b.stop() }
        b.type("hh")
        try await b.paste()
        b.type("after")
        b.caret(at: b.length)
        b.send(Self.homeExtending)
        #expect(b.selection == NSRange(location: 3, length: 5), "the line's text only (\(b.selection))")
        b.caret(at: 0)
        b.send(Self.endExtending)
        #expect(b.selection == NSRange(location: 0, length: 2), "the text before the picture only (\(b.selection))")
    }

    /// With no picture, the keys keep AppKit's meaning: the start and end of the caret's line.
    @Test func withoutAPictureTheKeysMoveAsBefore() async throws {
        let b = try await box()
        defer { b.stop() }
        b.type("first")
        b.field.insertNewlineIgnoringFieldEditor(nil)
        b.type("second")
        b.caret(at: b.length)
        b.send(Self.home)
        #expect(b.selection == NSRange(location: 6, length: 0), "\(b.selection)")
        b.caret(at: 2)
        b.send(Self.end)
        #expect(b.selection == NSRange(location: 5, length: 0), "\(b.selection)")
    }
}
