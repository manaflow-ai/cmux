import AppKit
@testable import CmuxNextFloating
import Foundation
import Testing

/// Message the Chief (`home.messageChiefPet`): it summons the pet with its reply box open, at once.
/// With `home.chiefPetEnabled` off the pet shows for that message only and goes when the box closes,
/// so the setting stays off; the setting turning on keeps it. An open box stays open (it is not the
/// click's toggle).
@MainActor @Suite(.serialized) struct ChiefPetSummonTests {
    static func controller() -> ChiefPetController {
        let name = "ChiefPetSummonTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return ChiefPetController(makePanel: { ChiefPetPanel(defaults: defaults) },
                                  actions: ChiefPetActions(open: { _ in }, send: { _, _ in true }))
    }

    @Test func aSummonWhileThePetIsOffShowsItForThisMessageOnly() {
        let controller = Self.controller()
        defer { controller.closeReply(); controller.sync(false) }
        controller.sync(false)
        controller.summon(petOn: false)
        #expect(controller.isShown, "the pet shows as the box's anchor")
        #expect(controller.replyPanel?.isVisible == true)
        #expect(!controller.isOn, "the setting is untouched")
        controller.closeReply()
        #expect(!controller.isShown, "closing the box takes the pet with it")
        controller.summon(petOn: false)
        #expect(controller.isShown && controller.replyPanel?.isVisible == true, "each message shows it again")
    }

    @Test func turningThePetOnWhileTheBoxIsOpenKeepsThePet() {
        let controller = Self.controller()
        defer { controller.closeReply(); controller.sync(false) }
        controller.summon(petOn: false)
        controller.sync(true)
        #expect(controller.replyPanel?.isVisible == true, "the open box stays")
        controller.closeReply()
        #expect(controller.isShown, "on now: the pet stays after the box closes")
    }

    @Test func aSummonRightAfterHideChiefPetKeepsTheBoxUntilItCloses() {
        let controller = Self.controller()
        defer { controller.closeReply(); controller.sync(false) }
        controller.sync(true)
        // Hide Chief Pet has landed but the controller has not followed it yet.
        controller.summon(petOn: false)
        controller.sync(false)
        #expect(controller.isShown && controller.replyPanel?.isVisible == true, "the box Message the Chief opened stays")
        controller.closeReply()
        #expect(!controller.isShown)
    }

    @Test func aSummonWhileThePetShowsOpensTheBoxAndKeepsItOpen() {
        let controller = Self.controller()
        defer { controller.closeReply(); controller.sync(false) }
        controller.sync(true)
        controller.summon(petOn: true)
        #expect(controller.replyPanel?.isVisible == true)
        controller.summon(petOn: true)
        #expect(controller.replyPanel?.isVisible == true, "a second summon is no toggle")
        controller.closeReply()
        #expect(controller.isShown, "the pet the person turned on stays")
    }

    @Test func turningThePetOffClosesTheBoxItOpenedWhileOn() {
        let controller = Self.controller()
        controller.sync(true)
        controller.summon(petOn: true)
        controller.sync(false)
        #expect(controller.replyPanel?.isVisible != true)
        #expect(!controller.isShown)
    }
}
