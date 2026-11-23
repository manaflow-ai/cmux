import AppKit
@testable import CmuxNextFloating
import CmuxNextTestSupport
import Foundation
import Testing

/// The hover dock (Leo 2026-10-20, the ChatGPT Codex mini pet): the pointer on the pet opens its reply
/// box without taking the keys; leaving the pet and the box closes it after the delay unless the box
/// is in use; a click on the pet keeps the box the hover opened instead of toggling it away.
@MainActor @Suite(.serialized) struct ChiefPetHoverDockTests {
    static func controller() -> ChiefPetController {
        let name = "ChiefPetHoverDockTests.\(UUID().uuidString)"
        let defaults = UserDefaults(testSuiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return ChiefPetController(makePanel: { ChiefPetPanel(defaults: defaults) },
                                  actions: ChiefPetActions(open: { _ in }, send: { _, _ in true }))
    }

    @Test func leavingClosesOnlyAnIdleBoxTheHoverOpened() {
        #expect(ChiefPetHoverDock.closeDelay == .milliseconds(400))
        #expect(ChiefPetHoverDock.closesOnLeave(openedByHover: true, pointerOver: false, editing: false, text: ""))
        #expect(ChiefPetHoverDock.closesOnLeave(openedByHover: true, pointerOver: false, editing: false, text: "  \n"), "blank text is no text")
        #expect(!ChiefPetHoverDock.closesOnLeave(openedByHover: true, pointerOver: true, editing: false, text: ""), "the pointer came back")
        #expect(!ChiefPetHoverDock.closesOnLeave(openedByHover: true, pointerOver: false, editing: true, text: ""), "the field has the caret")
        #expect(!ChiefPetHoverDock.closesOnLeave(openedByHover: true, pointerOver: false, editing: false, text: "ship it"), "typed text stays")
        #expect(!ChiefPetHoverDock.closesOnLeave(openedByHover: false, pointerOver: false, editing: false, text: ""), "a click's box is not the hover's")
    }

    @Test func hoverOpensTheBoxAndLeavingClosesIt() {
        let controller = Self.controller()
        defer { controller.closeReply(); controller.sync(false) }
        controller.sync(true)
        #expect(controller.isShown)
        controller.panel?.onHover?(true)
        #expect(controller.replyPanel?.isVisible == true, "the pointer on the pet opens the box")
        #expect(controller.replyByHover)
        controller.pointer = { CGPoint(x: -100_000, y: -100_000) }
        controller.panel?.onHover?(false)
        // The delay's fire: the pointer is off both, the box idle.
        controller.closeHoverDockIfIdle()
        #expect(controller.replyPanel?.isVisible == false, "leaving closes the box the hover opened")
        #expect(!controller.replyByHover)
    }

    @Test func textOrThePointerKeepsTheBox() {
        let controller = Self.controller()
        defer { controller.closeReply(); controller.sync(false) }
        controller.sync(true)
        controller.panel?.onHover?(true)
        controller.replyPanel?.field.stringValue = "status?"
        controller.pointer = { CGPoint(x: -100_000, y: -100_000) }
        controller.closeHoverDockIfIdle()
        #expect(controller.replyPanel?.isVisible == true, "typed text keeps the box")
        controller.replyPanel?.field.stringValue = ""
        if let frame = controller.panel?.frame { controller.pointer = { CGPoint(x: frame.midX, y: frame.midY) } }
        controller.closeHoverDockIfIdle()
        #expect(controller.replyPanel?.isVisible == true, "the pointer back on the pet keeps the box")
    }

    @Test func aClickOnThePetKeepsTheBoxTheHoverOpened() {
        let controller = Self.controller()
        defer { controller.closeReply(); controller.sync(false) }
        controller.sync(true)
        controller.panel?.onHover?(true)
        controller.panel?.onClick?()
        #expect(controller.replyPanel?.isVisible == true, "the click takes the hover's box, not toggles it away")
        #expect(!controller.replyByHover, "it is the click's box now: leaving keeps it")
        controller.pointer = { CGPoint(x: -100_000, y: -100_000) }
        controller.closeHoverDockIfIdle()
        #expect(controller.replyPanel?.isVisible == true)
        controller.panel?.onClick?()
        #expect(controller.replyPanel?.isVisible == false, "a second click still closes it")
    }
}
