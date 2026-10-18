import AppKit
@testable import CmuxNextFloating
import Foundation
import Observation
import Testing

/// The Chief pet: a non-activating panel over every app and Space that keeps
/// its spot per screen, stays fully on screen, tells a click from a drag, and
/// shows only while it is turned on.
@MainActor @Suite(.serialized) struct ChiefPetTests {
    @Observable final class Flag {
        var on: Bool
        init(_ on: Bool) { self.on = on }
    }

    static func defaults() -> UserDefaults {
        let name = "ChiefPetTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    static let visible = CGRect(x: 0, y: 25, width: 1440, height: 850)
    static let size = ChiefPetPanel.petSize

    @Test func firstSpotIsTheBottomRightCorner() {
        let frame = ChiefPetPlacement.frame(saved: nil, size: Self.size, in: Self.visible)
        #expect(frame.maxX == Self.visible.maxX - ChiefPetPlacement.inset)
        #expect(frame.minY == Self.visible.minY + ChiefPetPlacement.inset)
        #expect(frame.size == Self.size)
    }

    @Test func savedSpotComesBackPerDisplay() {
        let placement = ChiefPetPlacement(defaults: Self.defaults())
        placement.save(CGPoint(x: 300, y: 400), onDisplay: "1")
        placement.save(CGPoint(x: 10, y: 40), onDisplay: "2")
        #expect(placement.origin(onDisplay: "1") == CGPoint(x: 300, y: 400))
        #expect(placement.origin(onDisplay: "2") == CGPoint(x: 10, y: 40))
        #expect(placement.origin(onDisplay: "3") == nil)
        let frame = ChiefPetPlacement.frame(saved: placement.origin(onDisplay: "1"), size: Self.size, in: Self.visible)
        #expect(frame.origin == CGPoint(x: 300, y: 400))
    }

    @Test func spotOffScreenIsPulledBackFullyOnScreen() {
        // Saved on a larger display, or past the menu bar and the Dock.
        for saved in [CGPoint(x: 5000, y: 5000), CGPoint(x: -200, y: -200), CGPoint(x: 1430, y: 0)] {
            let frame = ChiefPetPlacement.frame(saved: saved, size: Self.size, in: Self.visible)
            #expect(Self.visible.contains(frame), "\(saved) -> \(frame)")
        }
    }

    @Test func smallMovesAreClicksNotDrags() {
        let start = CGPoint(x: 100, y: 100)
        #expect(!ChiefPetPlacement.isDrag(from: start, to: CGPoint(x: 101, y: 102)))
        #expect(ChiefPetPlacement.isDrag(from: start, to: CGPoint(x: 103, y: 100)))
        #expect(ChiefPetPlacement.isDrag(from: start, to: CGPoint(x: 90, y: 120)))
    }

    @Test func panelFloatsOverEveryAppWithoutTakingFocus() {
        let panel = ChiefPetPanel(image: nil, defaults: Self.defaults())
        #expect(panel.styleMask.contains(.nonactivatingPanel))
        #expect(!panel.canBecomeKey)
        #expect(!panel.canBecomeMain)
        #expect(!panel.hidesOnDeactivate)
        #expect(panel.level == .floating)
        #expect(panel.collectionBehavior.contains(.canJoinAllSpaces))
        #expect(panel.collectionBehavior.contains(.fullScreenAuxiliary))
        #expect(panel.collectionBehavior.contains(.ignoresCycle))
        #expect(panel.accessibilityIdentifier() == ChiefPetPanel.accessibilityID)
        #expect(panel.pet.acceptsFirstMouse(for: nil))
    }

    /// One press through the view: down at `from`, dragged through `path`, up.
    private func press(_ pet: ChiefPetView, from: CGPoint, path: [CGPoint]) {
        var pointer = from
        pet.pointer = { pointer }
        let event = NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                                       windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        pet.mouseDown(with: event)
        for point in path {
            pointer = point
            pet.mouseDragged(with: event)
        }
        pet.mouseUp(with: event)
    }

    @Test func clickRunsOnClickAndDoesNotMove() {
        let panel = ChiefPetPanel(image: nil, defaults: Self.defaults())
        panel.setFrameOrigin(CGPoint(x: 200, y: 200))
        var clicks = 0
        var drags = 0
        panel.onClick = { clicks += 1 }
        panel.pet.onDragEnded = { drags += 1 }
        press(panel.pet, from: CGPoint(x: 220, y: 230), path: [CGPoint(x: 221, y: 231)])
        #expect(clicks == 1)
        #expect(drags == 0)
        #expect(panel.frame.origin == CGPoint(x: 200, y: 200))
    }

    @Test func dragMovesThePanelWithThePointerAndIsNotAClick() {
        let panel = ChiefPetPanel(image: nil, defaults: Self.defaults())
        panel.setFrameOrigin(CGPoint(x: 200, y: 200))
        var clicks = 0
        var drags = 0
        panel.onClick = { clicks += 1 }
        panel.pet.onDragEnded = { drags += 1 }
        press(panel.pet, from: CGPoint(x: 220, y: 230), path: [CGPoint(x: 240, y: 230), CGPoint(x: 320, y: 180)])
        #expect(clicks == 0)
        #expect(drags == 1)
        #expect(panel.frame.origin == CGPoint(x: 300, y: 150))
    }

    @Test func controllerShowsThePetOnlyWhileItIsOn() {
        let flag = Flag(false)
        let defaults = Self.defaults()
        var clicks = 0
        let controller = ChiefPetController(enabled: { flag.on }, makePanel: { ChiefPetPanel(image: nil, defaults: defaults) },
                                            onClick: { clicks += 1 })
        controller.sync(false)
        #expect(controller.panel == nil)
        controller.sync(true)
        #expect(controller.isShown)
        controller.panel?.onClick?()
        #expect(clicks == 1)
        let made = controller.panel
        controller.sync(false)
        #expect(!controller.isShown)
        controller.sync(true)
        // Made once: its spot and state are kept while it is hidden.
        #expect(controller.panel === made)
        controller.sync(false)
    }
}
