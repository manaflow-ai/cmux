import CmuxNextDesign
import Testing
@testable import CmuxNextTabs

/// The grouping rules every grouped strip shares (pane tab strips and the
/// screen bar): one reducer, one color rule, one collapse rule.
@Suite struct SharedGroupColorTests {
    @Test func aNewGroupTakesTheFirstUnusedColorAndNeverPicksBlue() {
        #expect(TabGroupOrdering.nextColor(used: []) == .grey)
        #expect(TabGroupOrdering.nextColor(used: [.grey]) == GroupColor.allCases.first { $0 != .grey && $0 != .blue })
        #expect(TabGroupOrdering.nextColor(used: GroupColor.allCases.filter { $0 != .blue }) == .grey, "all taken: grey")
        for used in [[GroupColor](), [.grey], [.grey, .red], [.red, .yellow, .green]] {
            #expect(TabGroupOrdering.nextColor(used: used) != .blue)
        }
    }
}

/// The selection a caller moves before collapsing a group over it.
@Suite struct SelectionBeforeCollapsingTests {
    static func tab(_ id: String, _ group: String?) -> TabItem {
        var item = TabItem(id: TabID(id), title: id)
        item.groupID = group.map { TabGroupID($0) }
        return item
    }

    @Test func nearestVisibleToTheRightThenLeft() {
        let tabs = [Self.tab("a", nil), Self.tab("b", "g"), Self.tab("c", "g"), Self.tab("d", nil)]
        #expect(TabGroupOrdering.selectionBeforeCollapsing(TabGroupID("g"), in: tabs, collapsed: [], selected: TabID("b")) == TabID("d"))
        let noRight = Array(tabs.dropLast())
        #expect(TabGroupOrdering.selectionBeforeCollapsing(TabGroupID("g"), in: noRight, collapsed: [], selected: TabID("c")) == TabID("a"))
    }

    /// Review finding: with every other item in a collapsed group, the
    /// selection must not stay hidden inside the collapsing group.
    @Test func everyOtherItemCollapsedFallsBackToTheFirstOutside() {
        let tabs = [Self.tab("a", "g1"), Self.tab("b", "g2")]
        #expect(TabGroupOrdering.selectionBeforeCollapsing(TabGroupID("g2"), in: tabs, collapsed: [TabGroupID("g1")], selected: TabID("b")) == TabID("a"))
    }

    @Test func nothingChangesWhenTheSelectionIsOutsideTheGroup() {
        let tabs = [Self.tab("a", nil), Self.tab("b", "g")]
        #expect(TabGroupOrdering.selectionBeforeCollapsing(TabGroupID("g"), in: tabs, collapsed: [], selected: TabID("a")) == nil)
    }
}

/// Seeded random sequences of group intents against the strip's reducer
/// (the one both tab groups and screen groups render through). After every
/// step: no item lost or duplicated (conservation on drag and regroup),
/// every item in at most one group with members contiguous, pinned items
/// never grouped, and group order unchanged by intents that do not move a
/// group.
@MainActor @Suite struct GroupReducerInvariantTests {
    /// SplitMix64, so failures reproduce from the seed.
    struct Random {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        mutating func below(_ n: Int) -> Int { Int(next() % UInt64(max(n, 1))) }
    }

    static func groupOrder(_ model: TabStripModel) -> [TabGroupID] {
        var seen: [TabGroupID] = []
        for tab in model.orderedTabs { if let g = tab.groupID, !seen.contains(g) { seen.append(g) } }
        return seen
    }

    static func violations(_ model: TabStripModel, ids: Set<TabID>) -> [String] {
        var bad: [String] = []
        let ordered = model.orderedTabs
        if Set(ordered.map(\.id)) != ids || ordered.count != ids.count { bad.append("conservation: \(ordered.map(\.id.rawValue))") }
        if ordered.contains(where: { $0.isPinned && $0.groupID != nil }) { bad.append("a pinned item is grouped") }
        var closed: Set<TabGroupID> = []
        var current: TabGroupID?
        for tab in ordered {
            if tab.groupID != current {
                if let current { closed.insert(current) }
                if let g = tab.groupID, closed.contains(g) { bad.append("group \(g.rawValue) not contiguous") }
                current = tab.groupID
            }
        }
        let groups = Set(model.groups.map(\.id))
        if ordered.contains(where: { $0.groupID.map { !groups.contains($0) } ?? false }) { bad.append("member of an unknown group") }
        return bad
    }

    @Test func randomGroupIntentsKeepTheInvariants() {
        var steps = 0
        var failure: String?
        for seed in 1...400 where failure == nil {
            var random = Random(state: UInt64(seed))
            let tabs = (0..<8).map { TabItem(id: TabID("t\($0)"), title: "\($0)", isPinned: $0 == 0) }
            let model = TabStripModel(tabs: tabs, selectedID: TabID("t3"))
            let ids = Set(tabs.map(\.id))
            var nextGroup = 0
            for _ in 0..<30 where failure == nil {
                let tab = tabs[random.below(tabs.count)].id
                let group = model.groups.isEmpty ? nil : model.groups[random.below(model.groups.count)].id
                let intent: TabStripIntent
                var keepsGroupOrder = false
                switch random.below(8) {
                case 0:
                    nextGroup += 1
                    let members = (0..<(1 + random.below(3))).map { _ in tabs[random.below(tabs.count)].id }
                    intent = .createGroup(TabGroupItem(id: TabGroupID("g\(nextGroup)")), tabs: members)
                case 1:
                    guard let group else { continue }
                    intent = .addToGroup(tab, group, index: random.below(2) == 0 ? nil : random.below(tabs.count))
                case 2:
                    intent = .removeFromGroup(tab, index: random.below(2) == 0 ? nil : random.below(tabs.count))
                case 3:
                    guard let group else { continue }
                    intent = .moveGroup(group, to: random.below(tabs.count + 1))
                case 4:
                    let from = model.orderedTabs.firstIndex { $0.id == tab } ?? 0
                    intent = .reorder(tab, from: from, to: random.below(tabs.count))
                case 5:
                    guard let group else { continue }
                    intent = .toggleGroupCollapsed(group)
                    keepsGroupOrder = true
                case 6:
                    guard let group else { continue }
                    intent = .group(.rename(group, name: "n"))
                    keepsGroupOrder = true
                default:
                    guard let group else { continue }
                    intent = .group(.ungroup(group))
                }
                let orderBefore = Self.groupOrder(model)
                model.apply(intent) { TabItem(id: TabID("fresh"), title: "") }
                steps += 1
                // A collapse over every visible item opens a fresh one; it joins the set.
                let current = ids.union(model.orderedTabs.map(\.id).filter { $0.rawValue == "fresh" })
                let bad = Self.violations(model, ids: current)
                if !bad.isEmpty { failure = "seed \(seed) after \(intent): \(bad)" }
                if keepsGroupOrder, Self.groupOrder(model) != orderBefore {
                    failure = "seed \(seed): \(intent) changed group order \(orderBefore) -> \(Self.groupOrder(model))"
                }
            }
        }
        print("group-reducer-invariants: \(steps) steps over 400 seeds")
        #expect(failure == nil, "\(failure ?? "")")
    }
}
