import Foundation
import Testing
@testable import CmuxMobileModel

@Suite struct TeamTests {
    @Test func dotsShowOnlineFirstAndOverflow() {
        let macs = (0..<8).map { MacDevice(id: "\($0)", name: "\($0)", isOnline: $0 == 6) }
        let result = Team(id: "t", name: "T", macs: macs).macDots()
        #expect(result.dots == [true, false, false, false, false])
        #expect(result.overflow == 3)
    }

    @Test func defaultColorIsStable() {
        #expect(TeamAppearance(defaultFor: "abc") == TeamAppearance(defaultFor: "abc"))
        #expect(TeamAppearance.palette.contains(TeamAppearance(defaultFor: "abc").colorHex))
    }

    @Test func glyphMapsToTheWireEmojiField() {
        var appearance = TeamAppearance(colorHex: "#30D158")
        #expect(appearance.glyph == .automatic)
        appearance.glyph = .none
        #expect(appearance.emoji == "")
        appearance.glyph = .custom("🚀")
        #expect(appearance.emoji == "🚀" && appearance.glyph == .custom("🚀"))
        appearance.glyph = .custom("ab")
        #expect(appearance.emoji == "b")
        appearance.glyph = .custom(" ")
        #expect(appearance.glyph == .automatic)
        appearance.glyph = .automatic
        #expect(appearance.emoji == nil)
    }

    @Test func transparentNeedsAnIcon() {
        var appearance = TeamAppearance(colorHex: "#30D158")
        #expect(!appearance.canBeTransparent)
        appearance.isTransparent = true
        #expect(!appearance.isTransparent, "automatic letter is not an icon")
        appearance.glyph = .none
        appearance.isTransparent = true
        #expect(!appearance.isTransparent, "color only has no icon")
        appearance.glyph = .custom("🚀")
        #expect(appearance.canBeTransparent)
        appearance.isTransparent = true
        #expect(appearance.isTransparent && appearance.colorHex == "#30D158")
    }

    @Test func removingTheIconFallsBackToThePreviousColor() {
        for glyph in [TeamGlyph.automatic, .none] {
            var appearance = TeamAppearance(colorHex: "#BF5AF2", emoji: "🚀", transparent: true)
            #expect(appearance.isTransparent)
            appearance.glyph = glyph
            #expect(!appearance.isTransparent)
            #expect(appearance.colorHex == "#BF5AF2")
            // Putting an icon back does not bring transparency back on its own.
            appearance.glyph = .custom("Q")
            #expect(!appearance.isTransparent)
        }
        // A stored value with transparency but no icon draws its color.
        #expect(!TeamAppearance(colorHex: "#BF5AF2", emoji: nil, transparent: true).isTransparent)
        #expect(!TeamAppearance(colorHex: "#BF5AF2", emoji: "", transparent: true).isTransparent)
    }

    @Test func choosingAColorClearsTransparent() {
        var appearance = TeamAppearance(colorHex: "#30D158", emoji: "🚀", transparent: true)
        appearance.choose(colorHex: "#FF453A")
        #expect(!appearance.isTransparent && appearance.colorHex == "#FF453A")
    }

    @Test func storedAppearanceDecodesWithoutTransparent() throws {
        // Saved by a build that predates transparent backgrounds.
        let legacy = Data(##"{"colorHex":"#0A84FF","emoji":"🚀"}"##.utf8)
        let decoded = try JSONDecoder().decode(TeamAppearance.self, from: legacy)
        #expect(decoded == TeamAppearance(colorHex: "#0A84FF", emoji: "🚀"))
        #expect(!decoded.isTransparent)
        let transparent = TeamAppearance(colorHex: "#0A84FF", emoji: "🚀", transparent: true)
        let roundTrip = try JSONDecoder().decode(TeamAppearance.self, from: JSONEncoder().encode(transparent))
        #expect(roundTrip == transparent && roundTrip.isTransparent)
    }

    @Test func characterTakesTheNewestGrapheme() {
        #expect(TeamGlyph.character(from: "A🇯🇵") == "🇯🇵")
        #expect(TeamGlyph.character(from: "👩‍👩‍👧") == "👩‍👩‍👧")
        #expect(TeamGlyph.character(from: "x \n") == "x")
        #expect(TeamGlyph.character(from: "") == nil)
    }

    @MainActor @Test func openingTabPrefersLastUsed() {
        let store = AppStore.mock(tabMemory: .inMemory())
        let ws = store.workspaces[0]
        #expect(store.openingTab(for: ws)?.id == "t-claude")
        store.noteOpened(tabID: "t-zsh", in: ws.id)
        #expect(store.openingTab(for: ws)?.id == "t-zsh")
    }
}

@MainActor @Suite struct AccountTeamTests {
    @Test func accountTeamsReplaceMockTeamsAndKeepSelection() {
        let store = AppStore.mock(tabMemory: .inMemory())
        store.applyAccountTeams([
            AppStore.AccountTeam(id: "a", name: "Alpha"),
            AppStore.AccountTeam(id: "b", name: "Beta"),
        ], selectedID: "b")
        #expect(store.teams.map(\.id) == ["a", "b"])
        #expect(store.activeTeamID == "b")
        #expect(store.teams.allSatisfy { TeamAppearance.palette.contains($0.appearance.colorHex) || $0.appearance.emoji != nil })
    }

    @Test func unknownSelectionFallsBackToAMemberTeam() {
        let store = AppStore.mock(tabMemory: .inMemory())
        store.applyAccountTeams([AppStore.AccountTeam(id: "only", name: "Only")], selectedID: "gone")
        #expect(store.activeTeamID == "only")
    }
}
