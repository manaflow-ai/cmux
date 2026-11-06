import AppKit
import Testing
@testable import MessagesLabSidebar

/// NEW MESSAGE ROW X (user 2026-10-30, a screenshot of the Home list's "New Message" row: "on
/// hover on new message should be x button"). Messages for Mac shows a circled x at the trailing
/// edge of its New Message row while the pointer is over it; a click discards the draft. These
/// tests move real mouse events over a laid-out list and click the x.
@MainActor
@Suite(.serialized)
struct CmuxSidebarRowCloseTests {
    static let draft = "new-message"

    @MainActor
    final class Fixture {
        let window: NSWindow
        let view: CmuxSidebarView
        var closed: [String] = []

        init(width: CGFloat = 320, closable: String? = CmuxSidebarRowCloseTests.draft) {
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 600), styleMask: [.borderless],
                              backing: .buffered, defer: false)
            view = CmuxSidebarView(frame: NSRect(x: 0, y: 0, width: width, height: 600))
            window.contentView = view
            let now = Date(timeIntervalSince1970: 1_800_000_000)
            let ada = CmuxSidebarEntry.Person(id: "ada", name: "Ada", initials: "AD")
            view.show([
                CmuxSidebarEntry(id: "pinned", title: "Pinned", people: [ada], preview: "hi", previewSender: nil, lastAt: now, unreadCount: 0, pinned: true),
                CmuxSidebarEntry(id: CmuxSidebarRowCloseTests.draft, title: "New Message", people: [], preview: "", previewSender: nil,
                                 lastAt: .distantPast, unreadCount: 0, pinned: false),
                CmuxSidebarEntry(id: "other", title: "Other", people: [ada], preview: "yo", previewSender: nil, lastAt: now, unreadCount: 0, pinned: false),
            ], pinned: ["pinned"])
            view.closableID = closable
            view.closeTitle = "Close New Message"
            view.onClose = { [unowned self] in closed.append($0) }
            view.layoutSubtreeIfNeeded()
            view.controller.view.layoutSubtreeIfNeeded()
            view.controller.document.layoutSubtreeIfNeeded()
            view.controller.tile(force: true)
        }

        var document: NSView { view.controller.document }
        var button: NSButton { view.rowClose.button }

        func rect(_ id: String) -> CGRect? {
            let c = view.controller
            for (r, i) in c.rowItems.enumerated() where SidebarController.element(c.snapshot.items, i)?.id == id { return c.rowRect(r) }
            return nil
        }

        /// Moves the pointer to `point` in the document view, as AppKit's tracking area would report it.
        func hover(_ point: CGPoint) throws {
            let location = document.convert(point, to: nil)
            let event = try #require(NSEvent.mouseEvent(with: .mouseMoved, location: location, modifierFlags: [], timestamp: 0,
                                                        windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0))
            view.rowClose.mouseMoved(with: event)
        }

        func leave() throws {
            let event = try #require(NSEvent.enterExitEvent(with: .mouseExited, location: .zero, modifierFlags: [], timestamp: 0,
                                                            windowNumber: window.windowNumber, context: nil, eventNumber: 0, trackingNumber: 0,
                                                            userData: nil))
            view.rowClose.mouseExited(with: event)
        }
    }

    @Test(arguments: [false, true])
    func hoveringTheDraftRowShowsAnXAtItsTrailingEdge(dark: Bool) throws {
        let f = Fixture()
        f.window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let row = try #require(f.rect(Self.draft))
        #expect(f.button.isHidden, "no x before the pointer comes")
        try f.hover(CGPoint(x: row.midX, y: row.midY))
        #expect(!f.button.isHidden)
        #expect(f.button.superview === f.document, "the x scrolls with its row")
        #expect(row.contains(f.button.frame), "the x sits inside the row")
        #expect(f.button.frame.midX > row.midX, "at the trailing edge, clear of the avatar and name")
        #expect(abs(f.button.frame.midY - row.midY) <= 1, "centred on the row")
        #expect(f.button.accessibilityLabel() == "Close New Message")
    }

    @Test func theXLeavesWithThePointerAndShowsOnNoOtherRow() throws {
        let f = Fixture()
        let row = try #require(f.rect(Self.draft))
        let other = try #require(f.rect("other"))
        try f.hover(CGPoint(x: row.midX, y: row.midY))
        #expect(!f.button.isHidden)
        try f.hover(CGPoint(x: other.midX, y: other.midY))
        #expect(f.button.isHidden, "another conversation's row has no x")
        try f.hover(CGPoint(x: row.minX + 30, y: row.midY))
        #expect(!f.button.isHidden)
        try f.leave()
        #expect(f.button.isHidden)
    }

    @Test func clickingTheXReportsTheRowOnce() throws {
        let f = Fixture()
        let row = try #require(f.rect(Self.draft))
        try f.hover(CGPoint(x: row.midX, y: row.midY))
        f.button.performClick(nil)
        #expect(f.closed == [Self.draft])
        #expect(f.button.isHidden)
    }

    @Test func noClosableRowAndTheAvatarOnlyListShowNoX() throws {
        let none = Fixture(closable: nil)
        let row = try #require(none.rect(Self.draft))
        try none.hover(CGPoint(x: row.midX, y: row.midY))
        #expect(none.button.isHidden)

        let compact = Fixture(width: CmuxSidebarView.compactBelow - 20)
        let compactRow = try #require(compact.rect(Self.draft))
        try compact.hover(CGPoint(x: compactRow.midX, y: compactRow.midY))
        #expect(compact.button.isHidden, "the avatar-only list has no room for an x")
    }

    @Test func theXGoesWhenTheRowGoesUnderAStillPointer() throws {
        let f = Fixture()
        let row = try #require(f.rect(Self.draft))
        try f.hover(CGPoint(x: row.midX, y: row.midY))
        #expect(!f.button.isHidden)
        f.view.show(f.view.entries.filter { $0.id != Self.draft }, pinned: ["pinned"])
        #expect(f.button.isHidden)
    }
}
