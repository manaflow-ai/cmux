@testable import CmuxNextActions
import Testing

/// The palette order data (`ActionDescriptor+PaletteRank.swift`) names only palette actions, and
/// folds each action into at most one family, so no row is lost or listed twice.
struct PaletteRankCatalogTests {
    private let catalog = ActionCatalog.all

    @Test func everyListedIDIsAPaletteAction() {
        let visible = Set(catalog.filter(\.isPaletteVisible).map(\.id))
        let listed = ActionDescriptor.paletteDailyActions
            .union(ActionDescriptor.paletteNicheActions)
            .union(ActionDescriptor.paletteAliases.keys)
            .union(ActionDescriptor.paletteFamilies.flatMap { $0.members + ($0.parent.map { [$0] } ?? []) })
        for id in listed.sorted(by: { $0.rawValue < $1.rawValue }) {
            #expect(visible.contains(id), "\(id) is not a palette action")
        }
    }

    @Test func familiesDoNotOverlap() {
        var seen: [ActionID: String] = [:]
        let parents = Set(ActionDescriptor.paletteFamilies.compactMap(\.parent))
        #expect(Set(ActionDescriptor.paletteFamilies.map(\.id)).count == ActionDescriptor.paletteFamilies.count)
        for family in ActionDescriptor.paletteFamilies {
            #expect(!family.members.isEmpty, "\(family.id)")
            if family.parent == nil {
                #expect(!family.title.isEmpty && !family.symbol.isEmpty, "\(family.id)")
                #expect(family.members.count > 1, "\(family.id) folds one row into another row")
            }
            for member in family.members {
                #expect(seen[member] == nil, "\(member) is in \(seen[member] ?? "") and \(family.id)")
                #expect(!parents.contains(member), "\(member) is a parent and a member")
                seen[member] = family.id
            }
        }
    }

    @Test func tiersAreDisjointAndMembersAreNiche() {
        #expect(ActionDescriptor.paletteDailyActions.isDisjoint(with: ActionDescriptor.paletteNicheActions))
        for descriptor in catalog where descriptor.paletteFamily != nil {
            #expect(descriptor.paletteTier == .niche, "\(descriptor.id) is in a family but not niche")
        }
        let tiers = Dictionary(uniqueKeysWithValues: catalog.map { ($0.id, $0.paletteTier) })
        #expect(tiers["newTab.default"] == .daily)
        #expect(tiers["palette.copyWorkspaceID"] == .niche)
        #expect(tiers["space.color.red"] == .niche)
        #expect(tiers["about"] == .standard)
    }
}
