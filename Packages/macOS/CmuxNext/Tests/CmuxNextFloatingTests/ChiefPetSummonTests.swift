import AppKit
@testable import CmuxNextFloating
import Foundation
import Testing

/// Message the Chief (`home.messageChiefPet`): it summons the pet with its reply box open. While the
/// pet is off the box opens as soon as the setting turns it on; while it shows, at once; an open box
/// stays open (it is not the click's toggle).
@MainActor @Suite(.serialized) struct ChiefPetSummonTests {
    static func controller() -> ChiefPetController {
        let name = "ChiefPetSummonTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return ChiefPetController(makePanel: { ChiefPetPanel(defaults: defaults) },
                                  actions: ChiefPetActions(open: { _ in }, send: { _, _ in true }))
    }

    @Test func aSummonWhileThePetIsOffOpensTheBoxOnceItShows() {
        let controller = Self.controller()
        defer { controller.sync(false) }
        controller.summon()
        #expect(controller.panel == nil, "off: the summon alone shows nothing (only the setting turns the pet on)")
        controller.sync(true)
        #expect(controller.isShown)
        #expect(controller.replyPanel?.isVisible == true, "the setting turning on brings the box with the pet")
        controller.closeReply()
        controller.sync(false)
        controller.sync(true)
        #expect(controller.replyPanel?.isVisible != true, "one summon opens the box once")
    }

    @Test func aSummonWhileThePetShowsOpensTheBoxAndKeepsItOpen() {
        let controller = Self.controller()
        defer { controller.sync(false) }
        controller.sync(true)
        controller.summon()
        #expect(controller.replyPanel?.isVisible == true)
        controller.summon()
        #expect(controller.replyPanel?.isVisible == true, "a second summon is no toggle")
    }

    @Test func turningThePetOffDropsAWaitingSummon() {
        let controller = Self.controller()
        controller.summon()
        controller.sync(false)
        controller.sync(true)
        defer { controller.sync(false) }
        #expect(controller.replyPanel?.isVisible != true)
    }
}
