import CmuxNextDesign
@testable import CmuxNextSidebar
import CoreGraphics
import Testing

/// SIDEBAR ROW CHANGE stage 1: the scroll rule that reads the rows in view (`ListViewportChange` over two
/// `SidebarLayout`s) gives the same anchor, the same offsets and the same "moved by itself" as the rule of feat
/// c7d588bf3df1, which read every row (`ListViewportReference`, test code). Seeded random lists (loose rows, groups
/// with members, folded groups) and random changes to them (rows closed, rows added, one row moved, a fold, another
/// list), a random viewport, offset and selection.
///
///     swift test --filter SidebarViewportRuleEqualityTests
@MainActor @Suite struct SidebarViewportRuleEqualityTests {
    typealias Item = ListViewport<SidebarRowKey>.Item
    typealias Reference = ListViewportReference<SidebarRowKey>

    /// A seeded list: `count` nodes, each a loose workspace or a group of 1 to 4 members (some folded).
    static func nodes(_ random: inout ClosingPanesRandom, count: Int, tag: String) -> [SidebarNode] {
        (0..<count).map { index in
            guard random.chance(0.15) else {
                return .workspace(SidebarWorkspace(id: WorkspaceID("\(tag)-w\(index)"), title: "workspace \(index)"))
            }
            let members = (0..<Int(random.int(1...4))).map { SidebarWorkspace(id: WorkspaceID("\(tag)-g\(index)-\($0)"), title: "member \($0)") }
            return .group(SidebarGroup(id: GroupID("\(tag)-g\(index)"), name: "group \(index)", isCollapsed: random.chance(0.3), workspaces: members))
        }
    }

    /// A random index below `count`.
    static func index(_ random: inout ClosingPanesRandom, _ count: Int) -> Int { Int(random.int(0...UInt64(max(count, 1) - 1))) }

    /// One random change of `nodes`, by name.
    static func change(_ random: inout ClosingPanesRandom, _ nodes: [SidebarNode], seed: UInt64) -> (name: String, nodes: [SidebarNode]) {
        var next = nodes
        switch random.int(0...6) {
        case 0:
            next.remove(at: Self.index(&random, next.count))
            return ("one row closed", next)
        case 1:
            next.insert(.workspace(SidebarWorkspace(id: WorkspaceID("new-\(seed)"), title: "new")), at: Self.index(&random, next.count + 1))
            return ("one row added", next)
        case 2:
            let moved = next.remove(at: Self.index(&random, next.count))
            next.insert(moved, at: Self.index(&random, next.count + 1))
            return ("one row moved", next)
        case 3:
            for _ in 0..<Int(random.int(2...12)) where next.count > 1 { next.remove(at: Self.index(&random, next.count)) }
            for index in 0..<Int(random.int(0...6)) {
                next.insert(.workspace(SidebarWorkspace(id: WorkspaceID("new-\(seed)-\(index)"), title: "new")), at: Self.index(&random, next.count + 1))
            }
            return ("rows closed and added", next)
        case 4:
            let groups = next.indices.filter { if case .group = next[$0] { true } else { false } }
            guard !groups.isEmpty, case var .group(group) = next[random.pick(groups)] else { return ("no change", next) }
            group.isCollapsed.toggle()
            next[next.firstIndex { if case let .group(listed) = $0 { listed.id == group.id } else { false } } ?? 0] = .group(group)
            return ("a group folded or opened", next)
        case 5:
            next.shuffle(using: &random)
            return ("every row moved", next)
        default:
            return ("another list", Self.nodes(&random, count: Int(random.int(1...80)), tag: "other-\(seed)"))
        }
    }

    static func layout(_ nodes: [SidebarNode]) -> SidebarLayout {
        let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        return SidebarLayout.make(sections: [SidebarSection(kind: .machine(machine), nodes: nodes)], metrics: .standard, options: SidebarLayoutOptions())
    }

    static func reference(_ layout: SidebarLayout, height: CGFloat) -> Reference {
        Reference(items: layout.rows.map { Item(id: $0.key, start: $0.y, length: $0.height) }, viewport: height,
                  content: max(layout.totalHeight, height))
    }

    @Test func theRuleOfTheRowsInViewEqualsTheRuleOfEveryRow() {
        var compared = 0, anchors = 0, shifts = 0, reveals = 0
        for seed in UInt64(1)...600 {
            var random = ClosingPanesRandom(seed: seed)
            let nodes = Self.nodes(&random, count: Int(random.int(1...120)), tag: "s\(seed)")
            let (name, changed) = Self.change(&random, nodes, seed: seed)
            let old = Self.layout(nodes), new = Self.layout(changed)
            // The rows of a layout are sorted by place and do not overlap: what the search for the rows in view needs.
            for layout in [old, new] {
                for (row, next) in zip(layout.rows, layout.rows.dropFirst()) {
                    #expect(row.y <= next.y && row.maxY <= next.y + 0.001, "seed \(seed): rows \(row.key) and \(next.key) are not in order of place")
                }
            }
            for _ in 0..<6 {
                let height = CGFloat(random.int(60...900))
                let before = Self.reference(old, height: height), after = Self.reference(new, height: height)
                let rule = old.viewportChange(to: new, height: height)
                let top = max(0, old.totalHeight - height)
                let offset = random.chance(0.2) ? (random.chance(0.5) ? 0 : top) : (CGFloat(random.int(0...1_000)) / 1_000 * top).rounded()
                let label = "seed \(seed), \(name), \(old.rows.count) -> \(new.rows.count) rows, viewport \(height), offset \(offset)"
                // The rows in view, by the search and by a read of every row.
                let lower = offset + 0.01, upper = offset + height - 0.01
                #expect(SidebarLayoutViewportRows(layout: old).viewportPositions(endingAfter: lower, startingBefore: upper)
                    == old.rows.indices.filter { old.rows[$0].maxY > lower && old.rows[$0].y < upper }, "rows in view: \(label)")
                let anchor = before.anchor(at: offset, next: after)
                #expect(rule.anchor(at: offset) == anchor, "anchor: \(label)")
                let anchored = after.anchored(from: before, offset: offset)
                #expect(rule.anchored(offset: offset) == anchored, "anchored: \(label)")
                let keys = old.rows.map(\.key), newKeys = new.rows.map(\.key)
                let focused = keys.isEmpty || random.chance(0.1) ? nil : random.pick(keys)
                let newFocus = random.chance(0.5) ? focused : (newKeys.isEmpty || random.chance(0.1) ? nil : random.pick(newKeys))
                let userMoved = random.chance(0.2)
                let extent = newFocus.flatMap { key in random.chance(0.5) ? new.revealExtent(id: key, row: key, height: height) : nil }
                let settled = after.settle(from: before, offset: offset, focused: focused, newFocus: newFocus, padding: SidebarLayout.revealPadding,
                                           userMoved: userMoved, extent: extent)
                #expect(rule.settle(offset: offset, focused: focused, newFocus: newFocus, padding: SidebarLayout.revealPadding,
                                    userMoved: userMoved, extent: extent) == settled, "settle: \(label), focus \(String(describing: focused)) -> \(String(describing: newFocus))")
                #expect(rule.settle(offset: offset, anchored: anchored, focused: focused, newFocus: newFocus, padding: SidebarLayout.revealPadding,
                                    userMoved: userMoved, extent: extent) == settled, "settle from the anchored offset: \(label)")
                for key in [focused, newFocus].compactMap({ $0 }) + keys.prefix(3) {
                    #expect(rule.movedByItself(key) == before.movedByItself(key, in: after), "moved by itself \(key): \(label)")
                }
                compared += 1
                if anchor != nil { anchors += 1 }
                if anchored != offset { shifts += 1 }
                if settled != anchored { reveals += 1 }
            }
        }
        print("SidebarViewportRuleEquality: \(compared) cases, \(anchors) with an anchor, \(shifts) with an anchor shift, \(reveals) with a reveal")
        // The cases are not all the same one: each part of the rule ran many times.
        #expect(anchors > 500 && shifts > 100 && reveals > 100, "the cases do not cover the rule: \(anchors) anchors, \(shifts) shifts, \(reveals) reveals")
    }

    /// A group drag's layout (`SidebarGroupDragPlan.layout`) is the one layout whose rows are not in order of place:
    /// the carried rows stand in the gap, each row past the card's cut at the card's bottom, so a tall row there
    /// starts above the short row before it. The list gives that layout to the scroll rule in the first reload after
    /// a drop or a cancel. The rule must find the rows in view of it, and give the offsets of the rule that reads
    /// every row, to the dropped list, to the list without the group, and from the dropped list back.
    @Test func aGroupDragsLayoutGivesTheRuleOfEveryRow() {
        var compared = 0, outOfOrder = 0
        let spacing: CGFloat = 4
        for seed in UInt64(1)...300 {
            var random = ClosingPanesRandom(seed: seed)
            // The base (the list without the dragged group): loose rows of three heights.
            var baseRows: [SidebarRow] = []
            var y: CGFloat = 0
            for index in 0..<Int(random.int(3...60)) {
                let height = CGFloat(random.pick([20, 28, 44]))
                baseRows.append(SidebarGroupDragPlanTests.row(.workspace(WorkspaceID("d\(seed)-w\(index)")), y, height: height, index: index))
                y += height + spacing
            }
            let base = SidebarLayout(rows: baseRows, totalHeight: y, gapY: nil, gapHeight: 0, gapShift: 0)
            // The dragged group: its header and 2 to 8 members, y from the group's top.
            let group = GroupID("d\(seed)-g")
            var carried = [SidebarGroupDragPlanTests.row(.group(group), 0, height: 24, group: group)]
            var full: CGFloat = 24 + spacing
            for index in 0..<Int(random.int(2...8)) {
                let height = CGFloat(random.pick([20, 28, 44]))
                carried.append(SidebarGroupDragPlanTests.row(.workspace(WorkspaceID("d\(seed)-m\(index)")), full, height: height, group: group))
                full += height + spacing
            }
            let card = min(full - spacing, CGFloat(random.int(40...120)))
            let blocks = SidebarGroupDragPlan.blocks(of: base.rows)
            let plan = SidebarGroupDragPlan(blocks: blocks, groupTop: 0, card: card, lead: spacing, trail: spacing, carried: carried)
            let slot = Int(random.int(0...UInt64(blocks.count)))
            let drag = plan.layout(base, slot: slot)
            if zip(drag.rows, drag.rows.dropFirst()).contains(where: { $0.y > $1.y }) { outOfOrder += 1 }
            // The dropped list: the whole group at the slot, the rows at and below the slot under it.
            let slotTop = plan.top(of: slot)
            let cut = base.rows.firstIndex { $0.y >= slotTop - 0.5 } ?? base.rows.count
            var droppedRows = Array(base.rows[..<cut])
            for var row in carried {
                row.y += slotTop
                droppedRows.append(row)
            }
            for var row in base.rows[cut...] {
                row.y += full
                droppedRows.append(row)
            }
            let dropped = SidebarLayout(rows: droppedRows, totalHeight: base.totalHeight + full, gapY: nil, gapHeight: 0, gapShift: 0)
            for (name, old, new) in [("drag to dropped", drag, dropped), ("drag to cancelled", drag, base), ("dropped to drag", dropped, drag)] {
                for _ in 0..<4 {
                    let height = CGFloat(random.int(60...900))
                    let before = Self.reference(old, height: height), after = Self.reference(new, height: height)
                    let rule = old.viewportChange(to: new, height: height)
                    let top = max(0, old.totalHeight - height)
                    let offset = random.chance(0.2) ? (random.chance(0.5) ? 0 : top) : (CGFloat(random.int(0...1_000)) / 1_000 * top).rounded()
                    let label = "seed \(seed), \(name), slot \(slot), card \(card), \(old.rows.count) -> \(new.rows.count) rows, viewport \(height), offset \(offset)"
                    let lower = offset + 0.01, upper = offset + height - 0.01
                    #expect(SidebarLayoutViewportRows(layout: old).viewportPositions(endingAfter: lower, startingBefore: upper)
                        == old.rows.indices.filter { old.rows[$0].maxY > lower && old.rows[$0].y < upper }, "rows in view: \(label)")
                    #expect(rule.anchor(at: offset) == before.anchor(at: offset, next: after), "anchor: \(label)")
                    let anchored = after.anchored(from: before, offset: offset)
                    #expect(rule.anchored(offset: offset) == anchored, "anchored: \(label)")
                    let keys = old.rows.map(\.key), newKeys = new.rows.map(\.key)
                    let focused = random.chance(0.1) ? nil : random.pick(keys)
                    let newFocus = random.chance(0.5) ? focused : (random.chance(0.1) ? nil : random.pick(newKeys))
                    let userMoved = random.chance(0.2)
                    let settled = after.settle(from: before, offset: offset, focused: focused, newFocus: newFocus, padding: SidebarLayout.revealPadding,
                                               userMoved: userMoved, extent: nil)
                    #expect(rule.settle(offset: offset, anchored: anchored, focused: focused, newFocus: newFocus, padding: SidebarLayout.revealPadding,
                                        userMoved: userMoved, extent: nil) == settled, "settle: \(label), focus \(String(describing: focused)) -> \(String(describing: newFocus))")
                    for key in [focused, newFocus].compactMap({ $0 }) {
                        #expect(rule.movedByItself(key) == before.movedByItself(key, in: after), "moved by itself \(key): \(label)")
                    }
                    compared += 1
                }
            }
        }
        print("SidebarViewportRuleEquality group drag: \(compared) cases, \(outOfOrder) of 300 drag layouts not in order of place")
        // The case the search cannot take is there: many drag layouts have a row that starts above the row before it.
        #expect(outOfOrder > 30, "the drag layouts do not cover rows out of order: \(outOfOrder) of 300")
    }
}
