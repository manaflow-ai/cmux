import AppKit
@testable import CmuxNextBrowser
import Foundation
import Testing

/// One click on a trailing omnibar badge works while the browser window is
/// not key (user, 2026-10-28, "i have to click the star icon twice for it to
/// work"). AppKit gives a press in a window that is not key to the view that
/// `hitTest` finds there only when that view accepts the first mouse; else the
/// press only makes the window key and the second press acts.
@MainActor
struct OmnibarTrailingFirstClickTests {
    private func shownBar() -> (AddressBarView, NSWindow) {
        let bar = AddressBarView()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 80), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView!.addSubview(bar)
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 10),
            bar.widthAnchor.constraint(equalToConstant: 840),
            bar.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 20),
        ])
        bar.update(url: URL(string: "https://github.com/manaflow-ai/cmux"), security: .secure)
        bar.setBookmarkStar(.off)
        bar.setProfileBadge(BrowserProfileBadge(monogram: "A", color: nil, name: "Austin"))
        bar.setMachineBadge("cmux-lawrence", help: "cmux-lawrence")
        bar.setFocusModeBadge(armed: false)
        window.contentView!.layoutSubtreeIfNeeded()
        return (bar, window)
    }

    /// The press AppKit would deliver at the center of `view`: the view the
    /// window's frame view hits there.
    private func hit(at view: NSView, in window: NSWindow) -> NSView? {
        let frameView = window.contentView!.superview!
        let center = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: frameView.superview ?? frameView)
        return frameView.hitTest(center)
    }

    private func firstClickPress(_ view: NSView, in window: NSWindow) -> NSEvent {
        let point = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        return NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0,
                                  windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    private func badges(_ bar: AddressBarView) -> [(String, NSView)] {
        func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
            for sub in view.subviews {
                if let match = sub as? T { return match }
                if let match = find(type, in: sub) { return match }
            }
            return nil
        }
        return [
            ("bookmark star", bar.starButton),
            ("profile badge", find(ProfileBadgeView.self, in: bar)),
            ("machine badge", find(MachineBadgeView.self, in: bar)),
            ("focus mode badge", bar.focusModeBadgeView),
        ].compactMap { name, view in view.map { (name, $0) } }
    }

    @Test func everyTrailingBadgeTakesTheFirstClickOfAWindowThatIsNotKey() throws {
        let (bar, window) = shownBar()
        let shown = badges(bar)
        #expect(shown.count == 4)
        for (name, badge) in shown {
            #expect(!badge.isHidden, "\(name) shows")
            let target = try #require(hit(at: badge, in: window), "\(name): nothing at its center")
            #expect(target === badge, "\(name): the press lands on \(type(of: target)), not the badge")
            #expect(target.acceptsFirstMouse(for: firstClickPress(badge, in: window)),
                    "\(name): the first click in a window that is not key only activates the window")
        }
    }

    @Test func oneFirstClickOnTheStarPressesIt() throws {
        let (bar, window) = shownBar()
        var presses = 0
        bar.onBookmarkStar = { _ in presses += 1 }
        let event = firstClickPress(bar.starButton, in: window)
        let target = try #require(hit(at: bar.starButton, in: window))
        // AppKit's rule for a window that is not key: deliver only if the hit view accepts the first mouse.
        if target.acceptsFirstMouse(for: event) { target.mouseDown(with: event) }
        #expect(presses == 1)
    }
}
