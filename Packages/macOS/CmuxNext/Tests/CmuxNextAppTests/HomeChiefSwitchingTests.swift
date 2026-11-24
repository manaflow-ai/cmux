import AppKit
@testable import CmuxNextHome
import Testing

/// The Home page's switch and sidebar slide (the person, 2026-11-23: "switching chiefs is super
/// slow", "sidebar closing / opening transition should be much better").
@MainActor
@Suite struct HomeChiefSwitchingTests {
    @Test func switchingBackShowsTheKeptChat() {
        let column = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let chats = HomeChatStack<String, NSView>(column: column)
        var made = 0
        let make = { () -> NSView in made += 1; return NSView() }
        let a = chats.show("a", make: make)
        let b = chats.show("b", make: make)
        #expect(a.isHidden && !b.isHidden, "the chat left is hidden, not removed")
        #expect(a.superview === column && b.frame == column.bounds)
        #expect(chats.show("a", make: make) === a, "a switch back shows the view made before")
        #expect(made == 2 && !a.isHidden && b.isHidden)
        #expect(chats.ids == ["a", "b"])
        #expect(chats.show("b", hidden: true, make: make).isHidden, "the New Message page keeps it hidden")
    }

    @Test func oldestChatGoesPastTheLimit() {
        let column = NSView()
        let chats = HomeChatStack<Int, NSView>(column: column)
        let first = chats.show(0) { NSView() }
        for id in 1...HomeChatStack<Int, NSView>.limit { chats.show(id) { NSView() } }
        #expect(chats.ids.count == HomeChatStack<Int, NSView>.limit)
        #expect(first.superview == nil, "the oldest chat is removed")
        #expect(!chats.ids.contains(0))
    }

    @Test func aChatThatLeftTheListGoesButNeverTheShownOne() {
        let chats = HomeChatStack<String, NSView>(column: NSView())
        let a = chats.show("a") { NSView() }
        chats.show("b") { NSView() }
        let c = chats.show("c") { NSView() }
        chats.keep { $0 == "b" }
        #expect(chats.ids == ["c", "b"], "c shows, so it stays though it is not listed")
        #expect(a.superview == nil && c.superview != nil)
    }

    @Test func slideLandsOnItsTargetWithoutPassingIt() {
        var slide = HomeSidebarSlide(from: 0, to: 300, parameters: HomeSidebarSlide.baseSpring(open: true))
        var last: CGFloat = 0
        var frames = 0
        while !slide.isSettled, frames < 600 {
            slide.advance(1.0 / 120)
            #expect(slide.reveal >= last - 0.001 && slide.reveal <= 300.5, "never back, never past the end")
            last = slide.reveal
            frames += 1
        }
        #expect(slide.isSettled && abs(slide.reveal - 300) < 0.5)
        #expect(frames < 240, "a full open lands within two seconds at 120 Hz (\(frames) frames)")
    }

    @Test func aTurnAroundKeepsItsSpeedAndLands() {
        var slide = HomeSidebarSlide(from: 0, to: 300, parameters: HomeSidebarSlide.baseSpring(open: true))
        for _ in 0..<6 { slide.advance(1.0 / 60) }
        let midway = slide.reveal
        #expect(midway > 0 && midway < 300)
        slide.retarget(0, parameters: HomeSidebarSlide.baseSpring(open: false))
        slide.advance(1.0 / 60)
        #expect(abs(slide.reveal - midway) < 40, "no jump on the turn-around")
        for _ in 0..<240 where !slide.isSettled { slide.advance(1.0 / 60) }
        #expect(slide.isSettled && abs(slide.reveal) < 0.5)
    }
}
