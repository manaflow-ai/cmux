import AppKit
import CmuxNextDesign
@testable import CmuxNextHome
import Foundation
import Testing

/// The empty Chief conversation's front page (Leo 2026-10-19: the Chief setup screen should say
/// what is there now): the Chief's face and what the Chief does over the rows, and a Show / Hide
/// Chief Pet row.
@MainActor @Suite(.serialized) struct HomeChiefFrontPageTests {
    @Test func theHeroSaysWhatTheChiefDoesAboveTheRows() {
        let panel = HomeFirstRunView(frame: NSRect(x: 0, y: 0, width: 600, height: 700))
        panel.hero.setAvatar(picture: nil, text: HomeChiefAvatar.defaultText)
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

    /// The hero shows the header's face: the profile's picture, else its text, else 🫡.
    @Test func theHeroShowsTheChiefsFace() {
        let hero = HomeFirstRunHero(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        hero.setAvatar(picture: nil, text: HomeChiefAvatar.headerText(nil, hasPicture: false))
        #expect(hero.glyph.stringValue == "🫡")
        #expect(!hero.glyph.isHidden)
        #expect(hero.picture.isHidden)
        hero.setAvatar(picture: NSImage(size: NSSize(width: 8, height: 8)), text: nil)
        #expect(hero.glyph.isHidden)
        #expect(!hero.picture.isHidden)
    }
}
