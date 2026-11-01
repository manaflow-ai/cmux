import AppKit
@testable import CmuxNextChiefPetWiring
import CmuxNextFloating
@testable import CmuxNextHomeEngine
@testable import CmuxNextSettings
import Foundation
import Testing

/// Leo 2026-11-01: "we can reorder them a little bit so they orb doesn't come first ... obv i assume
/// this won't switch up what they've currently selected...?" The characters now run Series 1 without
/// the orbs, Mochi, Series 2, then the orbs. A choice is kept by its id, never its place: the default
/// Chief's in cmux.json (`home.chiefPetMascot`), every other Chief's in the app's defaults
/// (`home.chief.mascots`, participant id to character id). So the same saved choices read back the same
/// characters, a person who never picked still wears orb, and the grid checks a cell by its id.
@MainActor @Suite(.serialized) struct ChiefPetMascotOrderTests {
    /// The ids the characters had before the reorder, in their old order.
    static let seriesOne = ["orb", "orb-spark", "orb-hood", "machine", "machine-cyan", "machine-blue", "moon", "moon-blue", "fox", "mochi"]

    @Test func theOrbsNoLongerComeFirstAndEveryOldIdStays() {
        #expect(HomeChiefPetSetting.mascots.first != "orb")
        #expect(Array(HomeChiefPetSetting.mascots.suffix(3)) == ["orb", "orb-spark", "orb-hood"])
        #expect(Set(Self.seriesOne).isSubset(of: Set(HomeChiefPetSetting.mascots)), "no character was dropped or renamed")
        #expect(HomeChiefPetSetting.defaultMascot == "orb" && ChiefPetMascot.initial == .orb, "the default stays orb")
        for id in Self.seriesOne {
            let root = CmuxNextSettings.JSONValue.object(["home": .object(["chiefPetMascot": .string(id)])])
            let parsed = CmuxConfigSnapshot.parse(root, validDensities: [], validMetrics: [])
            #expect(parsed.homeChiefPetMascot == id && parsed.diagnostics.isEmpty, "\(id) still parses as itself")
        }
        for mascot in ChiefPetMascot.allCases {
            #expect(mascot.avatarURL != nil, "\(mascot.rawValue) has its avatar picture")
        }
    }

    @Test func savedChoicesReadBackTheSameCharacters() async throws {
        // The default Chief's choice, in cmux.json, as a person saved it before the reorder.
        let saved = try await ChiefPetPopoverPickerTests().make(#"{"home":{"chiefPetMascot":"moon"}}"#)
        defer { saved.tearDown() }
        let moon = try #require(ChiefPetPopoverPickerTests.name(of: "moon"))
        await saved.until { saved.checked() == [moon] }
        #expect(saved.settings.snapshot.homeChiefPetMascot == "moon")
        #expect(saved.checked() == [moon], "the popover checks the saved character, by id")

        // Another Chief's choice, in the app's defaults under the key it has always used.
        let suite = "cmux-chief-mascot-order-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(["agent_scout01": "machine-blue"], forKey: "home.chief.mascots")
        let picks = ChiefMascotPicks(defaults: defaults, defaultChief: HomeChiefAvatars.defaultChief)
        #expect(picks.mascot(of: "agent_scout01", in: saved.settings.snapshot) == "machine-blue")
        #expect(picks.mascot(of: nil, in: saved.settings.snapshot) == "moon")
        #expect(picks.mascot(of: "agent_never_picked", in: saved.settings.snapshot) == "orb")

        // A person who never picked still wears orb, and orb is the one checked, wherever it sits.
        let unset = try await ChiefPetPopoverPickerTests().make("{}")
        defer { unset.tearDown() }
        let orb = try #require(ChiefPetPopoverPickerTests.name(of: "orb"))
        await unset.until { unset.checked() == [orb] }
        #expect(unset.settings.snapshot.homeChiefPetMascot == "orb")
        #expect(unset.checked() == [orb])
        #expect(ChiefPetSettingsRows.avatarURL(of: nil) == ChiefPetMascot.orb.avatarURL)
    }

    @Test func theGridChecksByIdNotByPlace() {
        _ = NSApplication.shared
        let grid = ChiefPetMascotGrid(items: ChiefPetSettingsRows.mascotItems())
        #expect(grid.cells.first?.id != "orb", "orb is no longer the first cell")
        grid.select("machine-blue", enabled: true)
        #expect(grid.selectedID == "machine-blue")
        // An id that is no character (one retired later, say) checks the default, not the first cell.
        grid.select("retired-character", enabled: true)
        #expect(grid.selectedID == HomeChiefPetSetting.defaultMascot)
        #expect(ChiefPetSettingsRows.avatarURL(of: "retired-character") == ChiefPetMascot.orb.avatarURL)
    }
}
