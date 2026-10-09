import AppKit
import CmuxHomeCore
import Testing
@testable import MessagesLabHome

/// The Home pane on MessagesLab's own transcript selection (TranscriptAccess,
/// Selection.swift): a drag and a double or triple press select as Messages
/// does and copy in its format, a copy across a photo says [Photo], the text
/// menu offers the system's Services, and a press and hold for a tapback
/// takes the selection off.
@MainActor @Suite(.serialized) struct HomeSelectionTests {
    /// The pane in an offscreen window (the text menu and Services need one); the
    /// projection is kept so its intents (tapbacks) stay.
    @MainActor private final class Pane {
        let projection: HomeProjection, controller: ChatController, window: NSWindow
        init(_ items: [TranscriptItem]) {
            _ = NSApplication.shared
            (projection, controller) = Fixture2.projection()
            window = NSWindow(contentRect: controller.host.frame, styleMask: [.titled], backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            window.contentView = controller.host
            projection.apply(items: items, summary: Fixture2.summary(lastSeq: Seq(items.count)), typing: [], hasOlder: false)
            controller.host.layoutSubtreeIfNeeded(); controller.demo!.layoutIfNeeded(); controller.demo!.collection.layoutIfNeeded()
            controller.selection.refresh()
        }
    }

    private func event(_ type: NSEvent.EventType, clicks: Int = 1, shift: Bool = false) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: .zero, modifierFlags: shift ? .shift : [], timestamp: 0, windowNumber: 0, context: nil,
                           eventNumber: 0, clickCount: clicks, pressure: type == .leftMouseUp ? 0 : 1)!
    }

    /// The middle of character `i` of a short text bubble's first line (host coordinates).
    private func point(_ hit: MessagesWindowView.Hit, character i: Int) throws -> CGPoint {
        let tl = try #require(hit.row.text)
        let line = CTLineCreateWithAttributedString(tl.attributed(color: .white, linkColor: .white))
        let x = (CTLineGetOffsetForStringIndex(line, i, nil) + CTLineGetOffsetForStringIndex(line, i + 1, nil)) / 2
        return CGPoint(x: hit.body.minX + Fixture.bubblePadX + x, y: hit.body.minY + Fixture.bubblePadY + Fixture.lineHeight / 2)
    }

    /// Just right of the caret before character `i` (a drag end lands on that caret).
    private func caret(_ hit: MessagesWindowView.Hit, before i: Int) throws -> CGPoint {
        let tl = try #require(hit.row.text)
        let line = CTLineCreateWithAttributedString(tl.attributed(color: .white, linkColor: .white))
        let x = CTLineGetOffsetForStringIndex(line, i, nil) + 0.5
        return CGPoint(x: hit.body.minX + Fixture.bubblePadX + x, y: hit.body.minY + Fixture.bubblePadY + Fixture.lineHeight / 2)
    }

    private func drag(_ c: ChatController, from: CGPoint, to: CGPoint) {
        c.mouseDown(at: from, event(.leftMouseDown))
        c.mouseDragged(at: CGPoint(x: (from.x + to.x) / 2, y: (from.y + to.y) / 2), event(.leftMouseDragged))
        c.mouseDragged(at: to, event(.leftMouseDragged))
        c.mouseUp(at: to, event(.leftMouseUp))
    }

    @Test func aDragInsideABubbleCopiesTheSelectedText() throws {
        let pane = Pane([Fixture2.item(1, Fixture2.them, "alpha bravo charlie")])
        let c = pane.controller
        let a = try #require(c.demo!.lastTextRow(mine: false))
        drag(c, from: try caret(a, before: 6), to: try caret(a, before: 17))
        #expect(c.selection.selectedText == "bravo charl")
    }

    @Test func aDragAcrossSendersCopiesInMessagesFormat() throws {
        let pane = Pane([Fixture2.item(1, Fixture2.them, "First reply here"), Fixture2.item(2, Fixture2.me, "Second one mine")])
        let c = pane.controller
        let a = try #require(c.demo!.lastTextRow(mine: false)), b = try #require(c.demo!.lastTextRow(mine: true))
        drag(c, from: try caret(a, before: 0), to: CGPoint(x: b.body.maxX - Fixture.bubblePadX - 1, y: b.body.midY))
        #expect(c.selection.selectedText == "Chief:\r\tFirst reply here\r\rMe:\r\tSecond one mine")
    }

    @Test func aDoubleAndATriplePressSelectTheWordAndTheParagraph() throws {
        let pane = Pane([Fixture2.item(1, Fixture2.them, "alpha bravo charlie")])
        let c = pane.controller
        let a = try #require(c.demo!.lastTextRow(mine: false))
        let p = try point(a, character: 8)
        c.mouseDown(at: p, event(.leftMouseDown))
        c.mouseUp(at: p, event(.leftMouseUp))
        c.mouseDown(at: p, event(.leftMouseDown, clicks: 2))
        c.mouseUp(at: p, event(.leftMouseUp, clicks: 2))
        #expect(c.selection.selectedText == "bravo")
        c.mouseDown(at: p, event(.leftMouseDown, clicks: 3))
        c.mouseUp(at: p, event(.leftMouseUp, clicks: 3))
        #expect(c.selection.selectedText == "alpha bravo charlie")
    }

    @Test func aShiftClickExtendsTheSelection() throws {
        let pane = Pane([Fixture2.item(1, Fixture2.them, "alpha bravo charlie")])
        let c = pane.controller
        let a = try #require(c.demo!.lastTextRow(mine: false))
        let p = try point(a, character: 1)
        c.mouseDown(at: p, event(.leftMouseDown, clicks: 2))
        c.mouseUp(at: p, event(.leftMouseUp, clicks: 2))
        #expect(c.selection.selectedText == "alpha")
        let q = try point(a, character: 9)
        c.mouseDown(at: q, event(.leftMouseDown, shift: true))
        c.mouseUp(at: q, event(.leftMouseUp, shift: true))
        #expect(c.selection.selectedText.hasPrefix("alpha br"), "\(c.selection.selectedText)")
    }

    @Test func aCopyAcrossAPhotoSaysPhoto() throws {
        let ref = AttachmentRef(hash: "h-photo", name: "photo.png", mimeType: "image/png", byteCount: 10, width: 1200, height: 900)
        let photo = TranscriptItem(key: IdempotencyKey("k2"), seq: 2, author: Fixture2.them, parts: [.attachment(ref)],
                                   createdAt: Fixture2.start.addingTimeInterval(60), delivery: .committed, messageID: MessageID("msg_2"))
        let pane = Pane([Fixture2.item(1, Fixture2.them, "Before the photo"), photo, Fixture2.item(3, Fixture2.them, "After it")])
        let c = pane.controller
        let first = try #require(c.demo!.lastTextRow(mine: false) { $0.text?.text == "Before the photo" })
        let last = try #require(c.demo!.lastTextRow(mine: false) { $0.text?.text == "After it" })
        drag(c, from: try caret(first, before: 0), to: CGPoint(x: last.body.maxX - Fixture.bubblePadX - 1, y: last.body.midY))
        #expect(c.selection.selectedText == "Chief:\r\tBefore the photo\r\t\(SelText.photo)\r\tAfter it")
        #expect(SelText.photo == "[Photo]")
    }

    @Test func theTextMenuOffersServicesForASelection() throws {
        let pane = Pane([Fixture2.item(1, Fixture2.them, "alpha bravo charlie")])
        let c = pane.controller
        let a = try #require(c.demo!.lastTextRow(mine: false))
        let p = try point(a, character: 8)
        c.doubleClicked(p)
        c.mouseUp(at: p, event(.leftMouseUp, clicks: 2))
        let menu = try #require(c.menu(at: p), "a right-click on selected text opens the text menu")
        #expect(menu.items.contains { $0.title == "Services" && $0.submenu != nil })
        #expect(!menu.items.contains { $0.title == Strings.menuTapbackDetails }, "the text menu, not the message menu")
        let doc = c.host.scrollView.document
        #expect(doc.validRequestor(forSendType: .string, returnType: nil) as AnyObject? === doc)
        #expect(c.host.validRequestor(forSendType: .string, returnType: nil) as AnyObject? === doc)
        let pb = NSPasteboard(name: NSPasteboard.Name("cmux-home-selection-test-\(UUID().uuidString)"))
        defer { pb.releaseGlobally() }
        #expect((doc as AnyObject).writeSelection?(to: pb, types: [.string]) == true, "Services get the selected text")
        #expect(c.selection.selectedText == "bravo")
    }

    @Test func aPressAndHoldForATapbackTakesTheSelectionOff() throws {
        let pane = Pane([Fixture2.item(1, Fixture2.them, "alpha bravo charlie")])
        let c = pane.controller
        let a = try #require(c.demo!.lastTextRow(mine: false))
        let p = try point(a, character: 8)
        c.doubleClicked(p)
        c.mouseUp(at: p, event(.leftMouseUp, clicks: 2))
        #expect(c.selection.selectedText == "bravo")
        // A press on the highlight keeps the selection until the hold fires.
        c.mouseDown(at: p, event(.leftMouseDown))
        #expect(!c.selection.isEmpty)
        RunLoop.main.run(until: Date().addingTimeInterval(PressHold.delay + 0.3))
        #expect(c.picker != nil, "the tapback picker opened")
        #expect(c.selection.isEmpty, "the hold took the selection off")
        c.mouseUp(at: p, event(.leftMouseUp))
        c.closePicker()
    }

    @Test func aClickOnABubbleSelectsItAndOnEmptySpaceDoesNot() throws {
        let pane = Pane([Fixture2.item(1, Fixture2.them, "alpha bravo charlie")])
        let c = pane.controller
        let a = try #require(c.demo!.lastTextRow(mine: false))
        c.clicked(CGPoint(x: a.body.midX, y: a.body.midY))
        #expect(c.selection.selectedKey == a.key)
        c.clicked(CGPoint(x: c.host.bounds.midX, y: Fixture.headerHeight + 8))
        #expect(c.selection.selectedKey == nil)
    }
}
