import AppKit
@testable import CmuxHomeCore
import Foundation
import Testing
import UniformTypeIdentifiers
@testable import MessagesLabHome

/// Cmd+Z in the Chief's message box (cmux #48500). Nightly 4475022227601 (2026-11-20) ended on an
/// Edit > Undo: AppKit threw NSRangeException from `-[NSTextStorage(NSUndo)
/// _undoRedoAttributedSubstringFromRange:]`. The field's text changed under the typing undo's
/// ranges: the draft rebuilt it when a picture came in or left, and the field deleted the picture an
/// undo had just put back ("with an image it sometimes does nothing"), so the next undo read past
/// the end of the text. Undo and Redo must bring back exactly what the person deleted or pasted:
/// text, pictures, and both together, in the draft that a send takes too.
///
/// The real view (`MessagesLabHomeView`) over a real `HomeStore` on the mock owner, in an offscreen
/// window; the pictures go in through the paste's own path (`addDraftAttachment`), keys through the
/// field's own text input, and Undo and Redo are the window's undo manager (Edit > Undo's target).
/// A red run of the crash ends the test process with that NSRangeException.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3))) struct HomeComposerUndoTests {
    final class NoWake: ChatWakeScheduler {
        func schedule(after seconds: Double, _ action: @escaping @MainActor @Sendable () -> Void) {}
        func cancel() {}
    }

    static let conversation = ConversationID("conv_chief")

    private func until(_ condition: @escaping @MainActor () -> Bool) async {
        for _ in 0..<20_000 where !condition() { await Task.yield() }
    }

    @MainActor struct Rig {
        let store: HomeStore
        let window: NSWindow
        let view: MessagesLabHomeView
        let undo: UndoManager
        let root: URL
        var field: FieldTextView { view.controller.demo!.compose.textView.view }
        /// The field's pictures by id, in the text's order.
        var pictures: [String] {
            guard let s = field.textStorage else { return [] }
            var out: [String] = []
            s.enumerateAttribute(.attachment, in: NSRange(location: 0, length: s.length)) { v, _, _ in
                if let a = v as? ComposeInlineAttachment { out.append(a.attachmentID) }
            }
            return out
        }
        /// The draft's attachments (what a send takes), in order.
        var draft: [String] { view.draftAttachments.map(\.ref.hash) }
        /// The field's text without its pictures' characters.
        var words: String { Draft.stripMarks(field.string) }

        /// One Edit-menu or key step, as one undo group (the app's event groups it).
        func step(_ body: () -> Void) {
            undo.beginUndoGrouping()
            body()
            undo.endUndoGrouping()
        }
        func type(_ text: String) { step { field.insertText(text, replacementRange: field.selectedRange()) } }
        func backspace() { step { field.deleteBackward(nil) } }
        func selectAll() { field.setSelectedRange(NSRange(location: 0, length: (field.string as NSString).length)) }
        func close() {
            view.stop(); window.close(); store.stop()
            try? FileManager.default.removeItem(at: root)
        }
    }

    private func rig() async throws -> Rig {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("home-composer-undo-\(UUID().uuidString)", isDirectory: true)
        let store = HomeStore(source: MockHomeSource(options: .immediate), blobCacheDirectory: root.appendingPathComponent("blobs"))
        store.start()
        await until { store.me != nil && store.isOnline }
        await store.open(Self.conversation)
        await until { !store.transcript(for: Self.conversation).isEmpty }
        let me = try #require(store.me?.id)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 900), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let view = MessagesLabHomeView(store: store, conversation: Self.conversation, me: me, wake: NoWake(), replies: .streaming)
        view.frame = NSRect(x: 0, y: 0, width: 700, height: 900)
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        view.projection.refresh()
        let undo = try #require(window.undoManager)
        undo.groupsByEvent = false
        let r = Rig(store: store, window: window, view: view, undo: undo, root: root)
        window.makeFirstResponder(r.field)
        #expect(r.field.undoManager === undo, "the field's typing undo is the window's (Edit > Undo)")
        return r
    }

    /// A small PNG, as a pasted screenshot arrives (bytes, not a file); a different size per INDEX.
    private func screenshot(_ index: Int) throws -> Data {
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64 + index, pixelsHigh: 40, bitsPerSample: 8,
                                                samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                                bytesPerRow: 0, bitsPerPixel: 0))
        return try #require(rep.representation(using: .png, properties: [:]))
    }

    /// Pastes a picture at the caret through the paste's path; returns its id.
    private func paste(_ index: Int, into r: Rig) async throws -> String {
        let shot = try await r.store.prepareAttachment(data: try screenshot(index), typeIdentifier: UTType.png.identifier)
        await r.view.addDraftAttachment(shot)
        await until { r.pictures.contains(shot.ref.hash) }
        #expect(r.pictures.contains(shot.ref.hash), "the pasted picture shows in the field")
        return shot.ref.hash
    }

    /// The crash: a picture, a key after it, the picture deleted, then Cmd+Z again and again. The
    /// first undo must put the picture back (it did nothing), and the undo after it read past the
    /// field's end (NSRangeException). Every step back and forth keeps the field and the draft equal.
    @Test func undoAfterDeletingAPictureBringsItBackAndKeepsUndoing() async throws {
        let r = try await rig()
        defer { r.close() }
        let shot = try await paste(0, into: r)
        r.type("x")
        #expect(r.field.string == "\u{FFFC}x")
        r.field.setSelectedRange(NSRange(location: 1, length: 0))
        r.backspace()
        #expect(r.pictures.isEmpty && r.draft.isEmpty, "Delete took the picture out of the field and the draft")
        #expect(r.field.string == "x")

        r.undo.undo()
        #expect(r.pictures == [shot], "Cmd+Z puts the deleted picture back in the field")
        #expect(r.draft == [shot], "and in the draft a send takes")
        #expect(r.field.string == "\u{FFFC}x")
        #expect(r.view.draftText == r.field.string)

        r.undo.undo()  // the "x"
        #expect(r.field.string == "\u{FFFC}")
        #expect(r.draft == [shot])
        r.undo.undo()  // the paste
        #expect(r.field.string.isEmpty)
        #expect(r.pictures.isEmpty && r.draft.isEmpty, "Cmd+Z of the paste takes the picture out")
        #expect(!r.undo.canUndo)

        r.undo.redo()  // the paste again
        #expect(r.pictures == [shot] && r.draft == [shot], "Cmd+Shift+Z pastes it again")
        r.undo.redo()  // the "x"
        #expect(r.field.string == "\u{FFFC}x")
        r.undo.redo()  // the delete
        #expect(r.field.string == "x")
        #expect(r.pictures.isEmpty && r.draft.isEmpty)
        #expect(r.view.draftText == "x")
        r.undo.undo()
        #expect(r.pictures == [shot] && r.draft == [shot], "and Cmd+Z brings it back once more")
    }

    /// Cmd+Shift+Z after the Cmd+Z of a paste pastes the picture again. The undo of a paste is the
    /// field's own step (`undoDraftStep`). While Edit > Undo ran it, NSTextView's `shouldChangeText`
    /// put a redo entry on the stack with the range the edit replaced ({0, 1}, the picture), not
    /// the range its text has after the edit ({0, 0}): the Redo read past the end of the empty
    /// field and the app ended with NSRangeException in `-[NSUndoReplaceCharacters undoRedo:]`
    /// (the crash of the test above, a1318, 2026-11-21). A red run ends the test process.
    @Test func redoAfterUndoingAPastePastesThePictureAgain() async throws {
        let r = try await rig()
        defer { r.close() }
        let shot = try await paste(0, into: r)
        r.undo.undo()
        #expect(r.field.string.isEmpty && r.draft.isEmpty, "Cmd+Z takes the pasted picture out")
        try #require(r.undo.canRedo, "the Cmd+Z of the paste left no redo for it")
        r.undo.redo()
        #expect(r.field.string == "\u{FFFC}")
        #expect(r.pictures == [shot] && r.draft == [shot], "Cmd+Shift+Z pastes the picture again")
    }

    /// Text only: what Delete took comes back, and goes again on Redo.
    @Test func undoBringsBackDeletedText() async throws {
        let r = try await rig()
        defer { r.close() }
        r.type("hello world")
        r.selectAll()
        r.backspace()
        #expect(r.field.string.isEmpty)
        r.undo.undo()
        #expect(r.field.string == "hello world")
        #expect(r.view.draftText == "hello world")
        r.undo.redo()
        #expect(r.field.string.isEmpty)
        #expect(r.view.draftText.isEmpty)
        r.undo.undo()
        #expect(r.view.draftText == "hello world")
    }

    /// Text, a picture and more text selected together and deleted: one Cmd+Z brings back all of
    /// it, the picture between the words, in the draft's order a send takes.
    @Test func undoBringsBackTextAndAPictureDeletedTogether() async throws {
        let r = try await rig()
        defer { r.close() }
        r.type("look ")
        let shot = try await paste(0, into: r)
        r.field.setSelectedRange(NSRange(location: (r.field.string as NSString).length, length: 0))
        r.type(" here")
        let full = r.field.string
        #expect(full == "look \u{FFFC} here")
        r.selectAll()
        r.backspace()
        #expect(r.field.string.isEmpty && r.draft.isEmpty)

        r.undo.undo()
        #expect(r.field.string == full)
        #expect(r.pictures == [shot] && r.draft == [shot])
        #expect(r.view.controller.store?.state.ui.draft.pieces.map(Self.describe) == ["look", "picture", "here"])
        r.undo.redo()
        #expect(r.field.string.isEmpty && r.draft.isEmpty)
        r.undo.undo()
        #expect(r.field.string == full && r.draft == [shot])
    }

    /// Two pictures deleted with one Delete come back together, in their order.
    @Test func undoBringsBackTwoPicturesInTheirOrder() async throws {
        let r = try await rig()
        defer { r.close() }
        let first = try await paste(0, into: r)
        let second = try await paste(1, into: r)
        #expect(r.pictures == [first, second])
        r.selectAll()
        r.backspace()
        #expect(r.pictures.isEmpty && r.draft.isEmpty)
        r.undo.undo()
        #expect(r.pictures == [first, second])
        #expect(r.draft == [first, second])
        r.undo.undo()  // the second paste
        #expect(r.pictures == [first] && r.draft == [first])
        r.undo.redo()
        #expect(r.pictures == [first, second] && r.draft == [first, second])
    }

    /// Typing before a picture came in, then undo past the picture: the typing's ranges still fit.
    @Test func typingUndoesPastAPictureThatCameInBeforeIt() async throws {
        let r = try await rig()
        defer { r.close() }
        r.type("abc")
        r.field.setSelectedRange(NSRange(location: 0, length: 0))
        let shot = try await paste(0, into: r)
        #expect(r.field.string == "\u{FFFC}abc")
        r.undo.undo()  // the paste
        #expect(r.field.string == "abc" && r.draft.isEmpty)
        r.undo.undo()  // the typing
        #expect(r.field.string.isEmpty)
        r.undo.redo()
        r.undo.redo()
        #expect(r.field.string == "\u{FFFC}abc" && r.draft == [shot])
    }

    /// A send empties the field without an undo step: nothing on the stack points into the gone
    /// draft any more, so Cmd+Z after a send cannot read past the empty field.
    @Test func aSendLeavesNoUndoIntoTheSentDraft() async throws {
        let r = try await rig()
        defer { r.close() }
        r.type("hi ")
        _ = try await paste(0, into: r)
        #expect(r.view.sendDraft() == nil)
        await until { r.field.string.isEmpty }
        #expect(r.field.string.isEmpty)
        #expect(!r.undo.canUndo, "the stack still holds entries for the sent draft's text")
    }

    private static func describe(_ p: Draft.Piece) -> String {
        switch p {
        case let .text(t): t
        case .attachment: "picture"
        }
    }
}
