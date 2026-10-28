import AppKit
@testable import CmuxNextFloating
import Foundation
import Testing

/// The pet's drag follows each event's own screen point, not the live cursor: the
/// events below land far from wherever the real mouse rests, and the panel moves by their offsets.
@MainActor @Suite(.serialized) struct ChiefPetEventPointTests {
    @Test func aDragFollowsItsEventsNotTheLiveCursor() {
        let name = "ChiefPetEventPointTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let panel = ChiefPetPanel(defaults: defaults)
        panel.setFrameOrigin(CGPoint(x: 200, y: 200))
        var ended = 0
        panel.pet.onDragEnded = { ended += 1 }
        panel.pet.layoutSubtreeIfNeeded()
        let spot = panel.pet.convert(CGPoint(x: panel.pet.characterFrame.midX, y: panel.pet.characterFrame.midY), to: nil)
        let down = panel.convertPoint(toScreen: spot)
        let moved = CGPoint(x: down.x + 60, y: down.y - 30)

        panel.pet.mouseDown(with: Self.event(.leftMouseDown, at: down))
        panel.pet.mouseDragged(with: Self.event(.leftMouseDragged, at: moved))
        panel.pet.mouseUp(with: Self.event(.leftMouseUp, at: moved))

        #expect(panel.frame.origin == CGPoint(x: 260, y: 170), "the panel moves by the events' offset")
        #expect(ended == 1)
    }

    /// A mouse event at `point` on screen. It has no window, so its location is that screen point.
    static func event(_ type: NSEvent.EventType, at point: CGPoint) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                           eventNumber: 0, clickCount: 1, pressure: 1)!
    }
}
