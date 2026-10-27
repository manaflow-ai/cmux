import AppKit
@testable import CmuxHomeCore
import CmuxNextDesign
@testable import CmuxNextHome
import Foundation
@testable import MessagesLabHome
import MessagesLabSidebar
import Testing

/// Home's invalidation discipline (plans/cmux-next/chrome-parity/p03-rendering.md R4, task 063): a
/// Home view asks for a layout or a redraw only when a value it lays out or draws changed, and a
/// child never invalidates its ancestor; the owner that changed the child's size does. Chrome
/// marks a LayoutObject dirty only on a style or geometry change (`LayoutObject::SetNeedsLayout`
/// callers compare first, third_party/blink/renderer/core/layout/layout_object.cc).
@MainActor @Suite(.serialized) struct HomeInvalidationDisciplineTests {
    private static let keys = HomeSwitchKeys(tabByNumber: "⌃1…9", workspaceByNumber: "⌘1…9", nextPreviousTab: "⇧⌘[ ⇧⌘]",
                                             nextPreviousWorkspace: nil, focusBackForward: nil)

    /// The binding table re-delivers the same shortcuts (a rebind elsewhere): the first-run panel,
    /// its rows and its card stay laid out.
    @Test func theSameFirstRunShortcutsLayNothingOut() {
        let panel = HomeFirstRunView(frame: NSRect(x: 0, y: 0, width: 600, height: 700))
        panel.setShortcuts(terminal: "⌘T", agent: "⌘I", switching: Self.keys)
        panel.layoutSubtreeIfNeeded()
        panel.setShortcuts(terminal: "⌘T", agent: "⌘I", switching: Self.keys)
        #expect(!panel.needsLayout, "the same card: the panel keeps its layout")
        #expect(!panel.terminal.needsLayout && !panel.agent.needsLayout, "the same shortcut: the row keeps its layout")
        #expect(!panel.switchCard.needsLayout, "the same keys: the card keeps its lines")

        panel.setShortcuts(terminal: "⌘N", agent: "⌘I", switching: Self.keys)
        #expect(panel.terminal.needsLayout, "a new shortcut lays its row out")
        #expect(!panel.agent.needsLayout)

        panel.setShortcuts(terminal: "⌘N", agent: "⌘I", switching: nil)
        #expect(panel.switchCard.isHidden)
        #expect(panel.needsLayout, "the card went: the panel lays out again")
    }

    /// Hide on the Switching card clears it through the same guarded path.
    @Test func hidingTheSwitchCardLaysThePanelOutOnce() {
        let panel = HomeFirstRunView(frame: NSRect(x: 0, y: 0, width: 600, height: 700))
        panel.setShortcuts(terminal: "⌘T", agent: "⌘I", switching: Self.keys)
        panel.layoutSubtreeIfNeeded()
        panel.hideSwitchCard()
        #expect(panel.switchCard.isHidden)
        #expect(panel.needsLayout)
        #expect(panel.terminal.shortcut == "⌘T", "the rows keep their shortcuts")
        panel.layoutSubtreeIfNeeded()
        panel.hideSwitchCard()
        #expect(!panel.needsLayout, "already hidden: nothing to lay out")
    }

    /// The host resolves the Chief's face again (a new picture read, the same text): the hero
    /// lays out only for a new text face.
    @Test func theSameChiefFaceLaysTheHeroOutOnce() {
        let hero = HomeFirstRunHero(frame: NSRect(x: 0, y: 0, width: 340, height: 200))
        hero.setAvatar(picture: nil, text: "🫡")
        hero.layoutSubtreeIfNeeded()
        hero.setAvatar(picture: nil, text: "🫡")
        #expect(!hero.needsLayout)
        hero.setAvatar(picture: nil, text: "AB")
        #expect(hero.needsLayout)
        #expect(hero.glyph.stringValue == "AB")
    }

    /// A scale the rows already have lays nothing out.
    @Test func theSameScaleLaysTheRowsOutNever() {
        let panel = HomeFirstRunView(frame: NSRect(x: 0, y: 0, width: 600, height: 700))
        panel.layoutSubtreeIfNeeded()
        panel.terminal.applyScale(1)
        #expect(!panel.terminal.needsLayout)
        panel.terminal.applyScale(1.25)
        #expect(panel.terminal.needsLayout)
    }

    /// A toggle's state change keeps the bar's buttons and size: neither the bar nor the header
    /// that places it lays out.
    @Test func aPanelToggleStateChangeLeavesTheHeaderAlone() {
        let header = LayoutRequestCounter(frame: NSRect(x: 0, y: 0, width: 400, height: 56))
        let bar = HomeHeaderPanelBar()
        header.addSubview(bar)
        bar.set([Self.memory(on: false), Self.sidebar])
        header.layoutSubtreeIfNeeded()
        header.requests = 0
        bar.set([Self.memory(on: true), Self.sidebar])
        #expect(bar.buttons.map(\.isOn) == [true, false])
        #expect(!bar.needsLayout, "the same buttons stay where they are")
        bar.set([Self.memory(on: true)])
        #expect(bar.needsLayout, "new buttons to place")
        #expect(header.requests == 0, "the bar never invalidates its ancestor; its owner does")
    }

    /// The owner of the bar (the transcript view) re-places it when its size changed.
    @Test func theTranscriptRePlacesTheBarWhenItsSizeChanges() throws {
        let home = HomeStore(source: MockHomeSource(options: .immediate))
        let view = HomeNativeTranscriptView(store: home, conversation: ConversationID("conv_invalidation"), me: ParticipantID("user_me"),
                                            mainWork: linklessMainWork())
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 700), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 700, height: 700))
        window.contentView = container
        view.frame = container.bounds
        container.addSubview(view)
        view.setHeaderPanels([Self.memory(on: false)])
        container.layoutSubtreeIfNeeded()
        #expect(view.headerPanels.frame.width == HomeHeaderPanelBar.buttonSize)
        view.setHeaderPanels([Self.memory(on: false), Self.sidebar])
        container.layoutSubtreeIfNeeded()
        #expect(view.headerPanels.frame.width == 2 * HomeHeaderPanelBar.buttonSize + HomeHeaderPanelBar.spacing)
        #expect(view.headerPanels.buttons.allSatisfy { $0.frame.maxX <= view.headerPanels.bounds.width })
    }

    /// Typing in the list's search field: the header lays out only when the search opens or closes.
    @Test func typingInTheSidebarSearchLaysTheHeaderOutOnlyWhenItOpensOrCloses() {
        let sidebar = HomeSidebarView(frame: NSRect(x: 0, y: 0, width: 320, height: 600))
        let header = sidebar.list.headerView
        let field = sidebar.list.searchField
        sidebar.layoutSubtreeIfNeeded()
        field.stringValue = "a"
        #expect(header.needsLayout, "the search opened")
        header.layoutSubtreeIfNeeded()
        field.stringValue = "ad"
        #expect(!header.needsLayout, "still open: the header keeps its layout")
        field.stringValue = ""
        #expect(header.needsLayout, "the search closed")
    }

    /// Typing in New Message's To: field never lays out the page that holds it: the field tells
    /// the page (`onGeometryChange`) only when the field or its suggestions change size.
    @Test func theToFieldTellsThePageOnlyAboutASizeChange() {
        let page = LayoutRequestCounter(frame: NSRect(x: 0, y: 0, width: 360, height: 600))
        let field = HomeNewMessageTests.field()
        field.frame.size.width = 360
        page.addSubview(field)
        page.layoutSubtreeIfNeeded()
        page.requests = 0
        var told = 0
        field.onGeometryChange = { told += 1 }
        field.refreshSuggestions()
        #expect(told == 1, "the first report")
        field.frame.size.height = field.height(forWidth: 360) // the page places the field
        page.requests = 0
        field.refreshSuggestions()
        #expect(told == 1, "the same list and height: nothing to place")
        field.text.stringValue = "a"
        field.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field.text))
        #expect(page.requests == 0, "the field never invalidates its ancestor")
        let typed = told
        field.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field.text))
        #expect(told == typed, "the same text again: the same suggestions")
        let oneLine = field.height(forWidth: 360)
        for contact in HomeNewMessageTests.contacts { field.choose(.contact(contact)) }
        #expect(field.height(forWidth: 360) > oneLine)
        #expect(told > typed, "the tokens wrapped: the page places a taller field")
        #expect(page.requests == 0)
    }

    /// The page narrowed the field after its last report, so the tokens wrapped to a second line;
    /// removing a token back to the height reported at the old width still tells the page: the
    /// field compares its height with the frame the page gave it, not with an old report.
    @Test func theToFieldTellsThePageAfterAWidthChange() {
        let field = HomeNewMessageTests.field()
        var told = 0
        // Like the page: each report lays the field out at its height for its width.
        field.onGeometryChange = { [unowned field] in
            told += 1
            field.frame.size.height = field.height(forWidth: field.bounds.width)
        }
        field.frame.size = NSSize(width: 1000, height: field.height(forWidth: 1000))
        for contact in HomeNewMessageTests.contacts { field.choose(.contact(contact)) }
        let oneLine = field.bounds.height
        #expect(oneLine == field.height(forWidth: 1000), "the page placed the tokens on one line")
        var narrow: CGFloat = 1000
        while narrow > 120, field.height(forWidth: narrow) == oneLine { narrow -= 10 }
        #expect(field.height(forWidth: narrow) > oneLine, "the tokens wrap at the narrow width")
        // The page resizes the field in its own layout; the field reports nothing for that.
        field.frame.size = NSSize(width: narrow, height: field.height(forWidth: narrow))
        told = 0
        while field.height(forWidth: narrow) > oneLine, !field.draft.tokens.isEmpty {
            field.removeToken(at: field.draft.tokens.count - 1)
        }
        #expect(told >= 1, "the field got shorter: the page was told")
        #expect(field.bounds.height == field.height(forWidth: narrow), "the page placed the field at its new height")
    }

    /// The host re-lists the toggles with only a state change: neither the transcript host nor its
    /// pane header lays out (the accessory's setter invalidates the whole host).
    @Test func aPanelToggleStateChangeLeavesTheTranscriptHostAlone() {
        let home = HomeStore(source: MockHomeSource(options: .immediate))
        let view = HomeNativeTranscriptView(store: home, conversation: ConversationID("conv_invalidation"), me: ParticipantID("user_me"),
                                            mainWork: linklessMainWork())
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 700), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 700, height: 700))
        window.contentView = container
        view.frame = container.bounds
        container.addSubview(view)
        view.setHeaderPanels([Self.memory(on: false), Self.sidebar])
        container.layoutSubtreeIfNeeded()
        let host = view.transcript.controller.host
        #expect(!host.needsLayout && !host.paneHeader.needsLayout && !view.needsLayout)
        view.setHeaderPanels([Self.memory(on: true), Self.sidebar])
        #expect(view.headerPanels.buttons.map(\.isOn) == [true, false])
        #expect(!host.needsLayout, "the same accessory: the transcript host keeps its layout")
        #expect(!host.paneHeader.needsLayout, "the same accessory: the header keeps its layout")
        #expect(!view.needsLayout)
        view.setHeaderPanels([])
        #expect(view.headerPanelItems.isEmpty)
        #expect(host.needsLayout, "the toggles went: the rows' top moves")
    }

    private static func memory(on: Bool) -> HomeHeaderPanelItem {
        HomeHeaderPanelItem(id: "memory", symbol: "brain", label: "Memory Inspector", isOn: on)
    }

    /// Counts `needsLayout = true` set on this view itself (what a child's ancestor invalidation does).
    private final class LayoutRequestCounter: NSView {
        var requests = 0
        override var needsLayout: Bool {
            didSet { if needsLayout { requests += 1 } }
        }
    }

    private static let sidebar = HomeHeaderPanelItem(id: "rightSidebar", symbol: "sidebar.right", label: "Right Sidebar", isOn: false)
}
