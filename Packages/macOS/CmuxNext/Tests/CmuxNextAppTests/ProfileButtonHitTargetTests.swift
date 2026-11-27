import AppKit
@testable import CmuxNextApp
@testable import CmuxNextSidebar
import Testing

/// The sidebar footer's profile button is one target: every part of the
/// avatar it draws opens the profile menu.
@MainActor @Suite(.serialized) struct ProfileButtonHitTargetTests {
    @Test func everyPartOfTheProfileButtonOpensItsMenu() async throws {
        let h = try await SidebarBandHideTests().make()
        defer { h.tearDown() }
        h.model.profileAvatar = SidebarAvatar(name: "Default", color: .blue)
        var opened = 0
        h.sidebar.profileMenuProvider = { NSMenu() }
        h.sidebar.footerBand.profileMenuPresenter = { _, _ in opened += 1 }
        await h.until { h.sidebar.footerBand.profileControl?.view.showsAvatar == true }
        let button = try #require(h.sidebar.footerBand.profileControl?.view)
        button.layoutSubtreeIfNeeded()

        let drawn = Self.drawnPoints(button.avatarView)
        try #require(!drawn.isEmpty, "the profile button drew nothing")
        var dead: [NSPoint] = []
        for point in drawn {
            let before = opened
            Self.click(button, at: button.convert(point, from: button.avatarView), in: h.window)
            if opened == before { dead.append(point) }
        }
        let corners = [
            NSPoint(x: 1, y: 1),
            NSPoint(x: button.bounds.width - 1, y: 1),
            NSPoint(x: 1, y: button.bounds.height - 1),
            NSPoint(x: button.bounds.width - 1, y: button.bounds.height - 1),
        ]
        for corner in corners {
            let before = opened
            Self.click(button, at: corner, in: h.window)
            if opened == before { dead.append(corner) }
        }
        #expect(dead.isEmpty, "\(dead.count) avatar or corner points did not open the profile menu")
    }

    /// The points of `view` it paints (alpha over half), one per 2 pt.
    static func drawnPoints(_ view: NSView) -> [NSPoint] {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return [] }
        view.cacheDisplay(in: view.bounds, to: rep)
        let scaleX = CGFloat(rep.pixelsWide) / max(1, view.bounds.width)
        let scaleY = CGFloat(rep.pixelsHigh) / max(1, view.bounds.height)
        var points: [NSPoint] = []
        for y in stride(from: 0.5, to: view.bounds.height, by: 2) {
            for x in stride(from: 0.5, to: view.bounds.width, by: 2) {
                let row = view.isFlipped ? y : view.bounds.height - y
                guard let color = rep.colorAt(x: Int(x * scaleX), y: Int(row * scaleY)), color.alphaComponent > 0.5 else { continue }
                points.append(NSPoint(x: x, y: y))
            }
        }
        return points
    }

    static func click(_ view: NSView, at point: NSPoint, in window: NSWindow) {
        let location = view.convert(point, to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: 0,
                                                 windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else { continue }
            if type == .leftMouseDown { view.mouseDown(with: event) } else { view.mouseUp(with: event) }
        }
    }
}
