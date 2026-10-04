import AppKit
import CmuxHomeCore
import Testing
@testable import MessagesLabHome

/// The field's Liquid Glass (FieldChrome: the field, "+" and emoji glass in
/// one NSGlassEffectContainerView) sits where MessagesLab's shared geometry
/// says, in a pane of any size, with or without history, after a resize.
@MainActor @Suite(.serialized) struct FieldGlassTests {
    func host(width: CGFloat, height: CGFloat, items: [TranscriptItem]) -> (NSWindow, HomeProjection, ChatController) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let (p, c) = Fixture2.projection()
        c.host.frame = NSRect(x: 0, y: 0, width: width, height: height)
        window.contentView = c.host
        p.apply(items: items, summary: Fixture2.summary(lastSeq: Seq(items.count)), typing: [], hasOlder: false)
        c.host.layoutSubtreeIfNeeded()
        return (window, p, c)
    }

    func expectGlassPlaced(_ c: ChatController, _ label: String) throws {
        let chrome = c.host.fieldChrome
        let demo = try #require(c.demo)
        #expect(chrome.frame == c.host.bounds, "\(label): chrome fills the host")
        #expect(chrome.container.frame == chrome.bounds, "\(label): the glass container fills the chrome (\(chrome.container.frame))")
        #expect(chrome.field.frame == demo.compose.fieldRect, "\(label): field glass at the field (\(chrome.field.frame) vs \(demo.compose.fieldRect))")
        #expect(!chrome.field.frame.isEmpty)
        for g in [chrome.field, chrome.plusGlass, chrome.emojiGlass] {
            #expect(c.host.bounds.contains(g.convert(g.bounds, to: c.host)), "\(label): \(g.frame) inside the pane")
            #expect(!g.isHiddenOrHasHiddenAncestor && g.alphaValue == 1 && (g.layer?.opacity ?? 1) == 1, "\(label): visible")
        }
        let order = c.host.subviews
        let chromeIndex = try #require(order.firstIndex(of: chrome))
        #expect(order.firstIndex(of: c.host.below)! < chromeIndex, "\(label): the rows are under the glass")
    }

    @Test func theGlassIsPlacedInAnEmptyAndAFullConversation() throws {
        let (w1, _, empty) = host(width: 808, height: 655, items: [])
        defer { w1.close() }
        try expectGlassPlaced(empty, "empty")
        let (w2, _, full) = host(width: 808, height: 655, items: Fixture2.history(40))
        defer { w2.close() }
        try expectGlassPlaced(full, "history")
    }

    @Test func theGlassFollowsAResize() throws {
        let (window, _, c) = host(width: 628, height: 900, items: Fixture2.history(20))
        defer { window.close() }
        try expectGlassPlaced(c, "628")
        c.host.frame = NSRect(x: 0, y: 0, width: 1100, height: 720)
        c.host.layoutSubtreeIfNeeded()
        try expectGlassPlaced(c, "1100")
    }
}
