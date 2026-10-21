import AppKit
@testable import CmuxNextFloating
import Foundation
import Testing

/// The Chief pet across screens: a drag over a display's edge follows the pointer and is pulled
/// back on screen only once it ends; a resolution change pulls it back too; and the reply box
/// moves with the pet instead of staying where it opened.
@MainActor @Suite(.serialized) struct ChiefPetScreenTests {
    static func defaults() -> UserDefaults {
        let name = "ChiefPetScreenTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    /// A 400 pt screen: the pet (136 pt wide) fits fully at x 264 at most.
    static let visible = CGRect(x: 0, y: 0, width: 400, height: 400)
    /// The panels' own center: a post here reaches no other suite's pet.
    static let notifications = NotificationCenter()

    static func panel() -> ChiefPetPanel {
        let panel = ChiefPetPanel(defaults: defaults(), notifications: Self.notifications)
        panel.visibleFrame = { Self.visible }
        panel.setFrameOrigin(CGPoint(x: 200, y: 200))
        return panel
    }

    /// Presses the character at `from` and drags through `path`; `release` false keeps the button down.
    private func drag(_ pet: ChiefPetView, from: CGPoint, path: [CGPoint], release: Bool = true) {
        var pointer = from
        pet.pointer = { pointer }
        pet.layoutSubtreeIfNeeded()
        let spot = CGPoint(x: pet.characterFrame.midX, y: pet.characterFrame.midY)
        let event = NSEvent.mouseEvent(with: .leftMouseDown, location: pet.convert(spot, to: nil), modifierFlags: [], timestamp: 0,
                                       windowNumber: pet.window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        pet.mouseDown(with: event)
        for point in path {
            pointer = point
            pet.mouseDragged(with: event)
        }
        if release { pet.mouseUp(with: event) }
    }

    @Test func aDragOverTheScreenEdgeIsNotPulledBackUntilItEnds() {
        let panel = Self.panel()
        // Over the right edge, onto the next display: AppKit reports the screen change mid-drag.
        drag(panel.pet, from: CGPoint(x: 220, y: 230), path: [CGPoint(x: 300, y: 230), CGPoint(x: 370, y: 230)], release: false)
        #expect(panel.frame.origin == CGPoint(x: 350, y: 200))
        panel.windowDidChangeScreen(Notification(name: NSWindow.didChangeScreenNotification, object: panel))
        #expect(panel.frame.origin == CGPoint(x: 350, y: 200), "mid-drag the pet stays under the pointer")
        Self.notifications.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        #expect(panel.frame.origin == CGPoint(x: 350, y: 200), "mid-drag the pet stays under the pointer")
        let up = NSEvent.mouseEvent(with: .leftMouseUp, location: .zero, modifierFlags: [], timestamp: 0,
                                    windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        panel.pet.mouseUp(with: up)
        #expect(panel.frame.origin == CGPoint(x: 264, y: 200), "released, it is pulled fully on screen")
    }

    @Test func aScreenChangeOutsideADragPullsThePetBackOnScreen() {
        let panel = Self.panel()
        panel.setFrameOrigin(CGPoint(x: 350, y: -40))
        panel.windowDidChangeScreen(Notification(name: NSWindow.didChangeScreenNotification, object: panel))
        #expect(panel.frame.origin == CGPoint(x: 264, y: 0))
    }

    @Test func aResolutionChangePullsThePetBackOnScreen() {
        // The screen stays the same, so AppKit sends no didChangeScreen: only the screen parameters change.
        let panel = Self.panel()
        panel.setFrameOrigin(CGPoint(x: 350, y: 380))
        Self.notifications.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        #expect(panel.frame.origin == CGPoint(x: 264, y: 400 - ChiefPetPanel.petSize.height))
    }

    @Test func theReplyBoxMovesWithThePet() throws {
        let defaults = Self.defaults()
        let controller = ChiefPetController(makePanel: { ChiefPetPanel(defaults: defaults) },
                                            actions: ChiefPetActions(open: { _ in }, send: { _, _ in true }))
        controller.sync(true)
        defer { controller.sync(false) }
        let panel = try #require(controller.panel)
        panel.visibleFrame = { CGRect(x: 0, y: 0, width: 4000, height: 4000) }
        panel.setFrameOrigin(CGPoint(x: 600, y: 200))
        controller.toggleReply()
        let reply = try #require(controller.replyPanel)
        #expect(reply.isVisible)
        #expect(reply.parent === panel, "a child of the pet, as the notices are")
        let before = reply.frame.origin
        drag(panel.pet, from: CGPoint(x: 620, y: 230), path: [CGPoint(x: 660, y: 230), CGPoint(x: 700, y: 260)], release: false)
        #expect(panel.frame.origin == CGPoint(x: 680, y: 230))
        #expect(reply.frame.origin == CGPoint(x: before.x + 80, y: before.y + 30), "mid-drag the box moves with the pet")
        let up = NSEvent.mouseEvent(with: .leftMouseUp, location: .zero, modifierFlags: [], timestamp: 0,
                                    windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        panel.pet.mouseUp(with: up)
        #expect(reply.frame.origin == CGPoint(x: before.x + 80, y: before.y + 30), "released, it stays over the pet")
        controller.closeReply()
        #expect(reply.parent == nil, "closed, it no longer comes back with the pet")
        #expect(!reply.isVisible)
    }
}
