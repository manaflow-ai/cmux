import AppKit
import CmuxNextDesign
import CmuxNextFloating
@testable import CmuxNextHome
import Foundation
import Testing

/// The empty Chief conversation's front page (Leo 2026-10-19: the Chief setup screen should say
/// what is there now, without the placeholder cat): the Chief pet's character and what the Chief
/// does over the rows, a Show / Hide Chief Pet row, and the character as the Chief's default face.
@MainActor @Suite(.serialized) struct HomeChiefFrontPageTests {
    @Test func theHeroSaysWhatTheChiefDoesAboveTheRows() {
        let panel = HomeFirstRunView(frame: NSRect(x: 0, y: 0, width: 600, height: 700))
        panel.hero.image = ChiefPetMascot.orb.image
        panel.layoutSubtreeIfNeeded()
        #expect(!panel.hero.isHidden)
        #expect(panel.hero.frame.height > HomeFirstRunHero.pictureSide)
        #expect(panel.hero.body.stringValue.contains("agents"))
        // Top to bottom: the hero, Start an agent, Open a terminal, then the pet row.
        let order = [panel.hero, panel.agent, panel.terminal, panel.pet].map { panel.convert($0.bounds, from: $0).minY }
        #expect(order == order.sorted())
    }

    @Test func aShortPaneDropsTheHeroBeforeAnyRow() {
        let panel = HomeFirstRunView(frame: NSRect(x: 0, y: 0, width: 600, height: 130))
        panel.layoutSubtreeIfNeeded()
        #expect(panel.hero.isHidden)
        #expect(panel.actionRows.allSatisfy { !$0.isHidden })
    }

    @Test func theDebugSwitchKeepsTheRowsOnlyPanel() {
        let panel = HomeFirstRunView(frame: NSRect(x: 0, y: 0, width: 600, height: 700))
        panel.showsHero = false
        panel.layoutSubtreeIfNeeded()
        #expect(panel.hero.isHidden)
        #expect(HomeTunables.all.contains { $0.key == "home.firstRun.hero" })
    }

    @Test func thePetRowReadsAsTheChangeAndRunsTheToggle() {
        let panel = HomeFirstRunView(frame: NSRect(x: 0, y: 0, width: 600, height: 700))
        var actions: [HomeFirstRunAction] = []
        panel.onAction = { actions.append($0) }
        #expect(panel.pet.title == HomeStrings.firstRunShowPet)
        panel.setPetShown(true)
        #expect(panel.pet.title == HomeStrings.firstRunHidePet)
        #expect(panel.pet.accessibilityPerformPress())
        #expect(actions == [.togglePet])
        panel.setPetShown(false)
        #expect(panel.pet.title == HomeStrings.firstRunShowPet)
    }

    @Test func theDefaultFaceIsThePetCharacterNotTheCat() {
        let settings = DesignSettings()
        let face = HomeChiefFace(settings: settings)
        settings.homeChiefPetMascot = "orb"
        #expect(face.picture != nil)
        guard case .picture(let url)? = face.tile else {
            Issue.record("the tile's default is a picture")
            return
        }
        #expect(url.lastPathComponent == "ChiefMascotOrb.png")
        settings.homeChiefPetMascot = "fox"
        guard case .picture(let fox)? = face.tile else {
            Issue.record("the tile's default is a picture")
            return
        }
        #expect(fox.lastPathComponent == "ChiefMascotFox.png")
        #expect(ChiefPetMascot(setting: "cat") == .orb)
    }
}
