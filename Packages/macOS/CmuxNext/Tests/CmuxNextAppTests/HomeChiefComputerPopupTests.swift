import AppKit
@testable import CmuxNextHomeEngine
import Foundation
import Testing

/// The chat's popup of the Chief's computer (cmux issue 31488): it pops up while the Chief uses its
/// computer during a turn; the computer itself lives in the Chief Settings card.
@MainActor @Suite(.serialized) struct HomeChiefComputerPopupTests {
    @Test func thePopupShowsOnlyWhileTheChiefActsDuringATurn() async {
        let feed = Feed(status: .init(used: true, computer: ("vm", "running"), acting: true))
        let popup = Self.popup(feed)
        let window = Self.window(popup)
        defer { window.close() }
        #expect(!popup.isShowing)
        popup.follow(working: true)
        await until { popup.isShowing }
        await until { popup.section.frames >= 1 }
        popup.follow(working: false)
        #expect(!popup.isShowing)
        #expect(!popup.section.isOpen)
        let reads = feed.statuses
        await settle()
        #expect(feed.statuses == reads, "an idle chat reads nothing")
    }

    @Test func aTurnThatDoesNotUseTheComputerNeverShowsIt() async {
        let feed = Feed(status: .init(used: true, computer: ("vm", "running"), acting: false))
        let popup = Self.popup(feed)
        let window = Self.window(popup)
        defer { window.close() }
        popup.follow(working: true)
        await until { feed.statuses >= 1 }
        await settle()
        #expect(!popup.isShowing)
        #expect(feed.screens == 0)
        popup.follow(working: false)
    }

    @Test func dismissingLastsForTheTurn() async {
        let feed = Feed(status: .init(used: true, computer: ("vm", "running"), acting: true))
        let popup = Self.popup(feed)
        let window = Self.window(popup)
        defer { window.close() }
        popup.follow(working: true)
        await until { popup.isShowing }
        // The ✕ is what a click there reaches, and nothing on the popup takes it first.
        popup.layoutSubtreeIfNeeded()
        let onX = popup.convert(CGPoint(x: popup.dismissButton.bounds.midX, y: popup.dismissButton.bounds.midY), from: popup.dismissButton)
        #expect(popup.hitTest(popup.convert(onX, to: popup.superview))?.isDescendant(of: popup.dismissButton) == true)
        #expect(popup.gestureRecognizers.isEmpty)
        popup.dismissButton.performClick(nil)
        #expect(!popup.isShowing)
        popup.follow(working: false)
        popup.follow(working: true)
        await until { popup.isShowing }
        popup.follow(working: false)
    }

    private static func popup(_ feed: Feed) -> HomeChiefComputerPopup {
        let popup = HomeChiefComputerPopup()
        popup.section.source = feed.source(paid: true)
        return popup
    }

    private static func window(_ view: NSView) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(view)
        return window
    }

    @MainActor final class Feed {
        var status: HomeChiefComputer.Status?
        var statuses = 0
        var screens = 0
        let image: CGImage?

        init(status: HomeChiefComputer.Status?, image: CGImage? = nil) {
            self.status = status
            self.image = image ?? CGContext(data: nil, width: 16, height: 10, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
        }

        func source(paid: Bool) -> HomeChiefComputerSection.Source {
            .init(paid: { paid }, chief: { "mario" }, status: { [self] in statuses += 1; return status }, screen: { [self] in screens += 1; return image })
        }
    }
}

@MainActor private func settle() async {
    for _ in 0..<200 { await Task.yield() }
}

@MainActor private func until(_ condition: () -> Bool) async {
    for _ in 0..<5000 where !condition() { await Task.yield() }
    #expect(condition())
}
