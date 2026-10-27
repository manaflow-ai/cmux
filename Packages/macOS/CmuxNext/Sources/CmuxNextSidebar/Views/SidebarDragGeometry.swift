public import CoreGraphics
import Foundation

/// The drag engine's per-mouse-move work (sidebar-v2 S5): pure geometry
/// over the slots the sidebar drew, and the acceptance table the reducer
/// gave once at the drag's begin (`SidebarMirror.acceptance`). No FFI, no
/// IPC, no layout pass: a list row is found by binary search over the
/// slots' y ranges, a tile by binary search over its lines and then over
/// the tiles of that line. The drop is one move (`SidebarDocTarget`).
public nonisolated struct SidebarDragGeometry: Sendable {
    /// One place the pointer can be over.
    public struct Slot: Hashable, Sendable {
        public enum Kind: Hashable, Sendable {
            /// A list row (top half before, bottom half after).
            case row
            /// A group header: the middle band drops into the group.
            case group
            /// A tile or chip on a flowed line (left half before, right half after).
            case tile
            /// A section's header or its empty drop zone: the drop goes first in it.
            case section
            /// An open empty group's row (`SidebarRowKey.emptyGroup`): the drop goes into the group.
            case emptyGroup
        }

        /// The acceptance table's key (the view row key).
        public var key: String
        /// The document item this slot draws; nil for a section slot.
        public var item: String?
        public var section: String
        /// The group the slot's item sits in.
        public var parent: String?
        public var frame: CGRect
        public var kind: Kind

        public init(key: String, item: String?, section: String, parent: String? = nil, frame: CGRect, kind: Kind) {
            self.key = key
            self.item = item
            self.section = section
            self.parent = parent
            self.frame = frame
            self.kind = kind
        }
    }

    public enum Zone: Hashable, Sendable { case before, into, after }

    /// What the pointer is over and what a drop there does.
    public struct Hit: Hashable, Sendable {
        public var slot: Slot
        public var zone: Zone
        /// The move a drop makes; nil when the reducer refuses it.
        public var target: SidebarDocTarget?
        /// The reducer's refusal (`cross_machine`, ...), for the refused lift.
        public var refusal: String?
    }

    /// The middle band of a group header that drops into the group.
    public static let intoBand: ClosedRange<CGFloat> = 0.25...0.75

    private let lines: [[Slot]]
    private let acceptance: [String: SidebarDocAcceptance]
    /// Each group header slot, by its key.
    private let groupHeaders: [String: Slot]
    /// Each group's block (its header and the member rows under it), by the group's key: the y range a drop
    /// before or after the whole group splits in half.
    private let groupBlocks: [String: ClosedRange<CGFloat>]
    /// Each group item's parent group item (nil at the top), from the header slots.
    private var groupParent: [String: String?] = [:]
    /// Each group item's header slot.
    private var groupSlot: [String: Slot] = [:]
    /// The bottom of each group item's whole subtree (its rows and its subgroups' rows).
    private var subtreeBottom: [String: CGFloat] = [:]
    /// The outliner rule's indent (nested-groups prototype): at the bottom edge of a nested block the
    /// pointer's x picks the level the drop goes to. Nil keeps the y-only rule.
    var outline: (indent: SidebarIndent, leading: CGFloat, width: CGFloat)?

    /// `slots` in any order; `acceptance` from the drag's begin (empty:
    /// every place is accepted, as for a mirror without the table).
    public init(slots: [Slot], acceptance: [String: SidebarDocAcceptance]) {
        let sorted = slots.sorted { $0.frame.minY != $1.frame.minY ? $0.frame.minY < $1.frame.minY : $0.frame.minX < $1.frame.minX }
        var lines: [[Slot]] = []
        for slot in sorted {
            if let last = lines.last?.last, slot.kind == .tile, last.kind == .tile, abs(last.frame.minY - slot.frame.minY) < 0.5 {
                lines[lines.count - 1].append(slot)
            } else {
                lines.append([slot])
            }
        }
        self.lines = lines
        self.acceptance = acceptance
        var headers: [String: Slot] = [:]
        for slot in slots where slot.kind == .group { headers[slot.key] = slot }
        var blocks: [String: ClosedRange<CGFloat>] = [:]
        for slot in slots {
            // A slot widens its own group's block and every enclosing group's: a subgroup sits in its parent's block.
            var group = slot.kind == .group ? slot.key : slot.parent
            var seen: Set<String> = []
            let range = slot.frame.minY...slot.frame.maxY
            while let id = group, seen.insert(id).inserted, let header = headers[id] {
                blocks[id] = blocks[id].map { min($0.lowerBound, range.lowerBound)...max($0.upperBound, range.upperBound) } ?? range
                group = header.parent
            }
        }
        groupHeaders = headers
        groupBlocks = blocks
        for slot in slots where slot.kind == .group {
            guard let item = slot.item else { continue }
            groupParent[item] = slot.parent
            groupSlot[item] = slot
        }
        for slot in slots where slot.kind != .section {
            var current = slot.kind == .group ? slot.item : slot.parent
            var seen = Set<String>()
            while let id = current, seen.insert(id).inserted, groupParent[id] != nil {
                subtreeBottom[id] = max(subtreeBottom[id] ?? -.infinity, slot.frame.maxY)
                current = groupParent[id] ?? nil
            }
        }
    }

    /// The level a slot draws at: a header at its tree level, a member one level under its group.
    func level(of slot: Slot) -> Int {
        var level = slot.kind == .group ? 0 : (slot.parent == nil ? 0 : 1)
        var current = slot.kind == .group ? slot.parent : slot.parent.flatMap { groupParent[$0] ?? nil }
        var seen = Set<String>()
        while let id = current, seen.insert(id).inserted {
            level += 1
            current = groupParent[id] ?? nil
        }
        return level
    }

    /// The outliner rule: a drop after the last row of a nested block, with the pointer left of that
    /// row's level, goes after the ancestor group whose level the pointer's x picks (drag out of a group).
    /// Only ancestors whose whole subtree ends at this row qualify: a drop never lands inside a block above.
    private func outlined(_ hit: Hit, x: CGFloat) -> Hit {
        guard let outline, hit.zone == .after, hit.slot.kind != .section, hit.slot.kind != .tile else { return hit }
        // The chain of places a drop at this bottom edge may go, deepest first.
        var chain: [(slot: Slot, level: Int)] = [(hit.slot, level(of: hit.slot))]
        var current = hit.slot.kind == .group ? hit.slot.item.flatMap { groupParent[$0] ?? nil } : hit.slot.parent
        // A group header's own "after" is inside its block when it is open: only a closed one (or a member row) ends it.
        if hit.slot.kind == .group, let item = hit.slot.item, (subtreeBottom[item] ?? hit.slot.frame.maxY) > hit.slot.frame.maxY + 0.5 { return hit }
        var seen = Set<String>()
        while let id = current, seen.insert(id).inserted, let header = groupSlot[id],
              abs((subtreeBottom[id] ?? header.frame.maxY) - hit.slot.frame.maxY) < 0.5 {
            chain.append((header, level(of: header)))
            current = groupParent[id] ?? nil
        }
        guard chain.count > 1 else { return hit }
        let deepest = chain[0].level, shallowest = chain[chain.count - 1].level
        let picked = outline.indent.level(atX: x - outline.leading, width: outline.width, in: shallowest...deepest)
        guard let place = chain.first(where: { $0.level <= picked }), place.slot != hit.slot, allows(place.slot, .after) else { return hit }
        return Hit(slot: place.slot, zone: .after, target: Self.target(place.slot, .after), refusal: nil)
    }

    /// The level a drop of `hit` lands at: a member of the group it goes into, else its slot's level.
    func dropLevel(_ hit: Hit) -> Int {
        hit.zone == .into ? level(of: hit.slot) + 1 : level(of: hit.slot)
    }

    /// The slot under `point` (or the nearest one above or below the
    /// slots), its zone and the move a drop there makes.
    ///
    /// A drop a group's rows refuse (a dragged group lands beside rows only at
    /// its own level or above, `accept.rs`; a workspace of another machine)
    /// goes before or after the whole group instead, by which half of the
    /// group's block holds `point`: over its header or any of its member rows,
    /// climbing to the nearest enclosing group that takes it. Without this, a
    /// dragged group found a slot only on the thin top and bottom bands of
    /// each header, and a member row's gap nested the group it reordered.
    public func hit(_ point: CGPoint) -> Hit? {
        guard let line = line(at: point.y) else { return nil }
        let slot = Self.slot(in: line, x: point.x)
        if slot.kind == .group, !allows(slot, .into), let around = around(group: slot.key, point) { return around }
        let zone = Self.zone(slot, point)
        if allows(slot, zone) { return outlined(Hit(slot: slot, zone: zone, target: Self.target(slot, zone), refusal: nil), x: point.x) }
        if let parent = slot.parent, let around = around(group: parent, point) { return around }
        let accepted = acceptance[slot.key] ?? slot.item.flatMap { acceptance[$0] }
        return Hit(slot: slot, zone: zone, target: nil, refusal: accepted?.refusal ?? "refused")
    }

    /// A drop right before or after the slot keyed `key` (a section's slot: first in it), if accepted there.
    ///
    /// A dragged group's slots use it (`SidebarListView+GroupDrag`): the drop goes beside a whole top-level block's
    /// first row, never into a group or beside one of its members, whatever the acceptance table would take there
    /// (since nested groups, a group may land among another group's members, which a reorder must not do).
    public func beside(_ key: String, after: Bool) -> Hit? {
        guard let slot = lines.lazy.flatMap({ $0 }).first(where: { $0.key == key }) else { return nil }
        let zone: Zone = slot.kind == .section ? .into : after ? .after : .before
        guard allows(slot, zone) else { return nil }
        return Hit(slot: slot, zone: zone, target: Self.target(slot, zone), refusal: nil)
    }

    /// Whether a drop at `zone` of `slot` is accepted.
    private func allows(_ slot: Slot, _ zone: Zone) -> Bool {
        guard let table = acceptance[slot.key] ?? slot.item.flatMap({ acceptance[$0] }) else {
            return acceptance.isEmpty || slot.kind == .section // a header the table lacks (one machine draws none) takes the drop
        }
        switch zone {
        case .before: return table.before
        case .into: return table.into
        case .after: return table.after
        }
    }

    /// A drop before (upper half of the block) or after (lower half) the whole group `group`, if accepted
    /// there, else around the group that holds it (a subgroup's block sits inside its parent's).
    private func around(group: String, _ point: CGPoint) -> Hit? {
        var current: String? = group
        var seen: Set<String> = []
        while let id = current, seen.insert(id).inserted, let header = groupHeaders[id], let block = groupBlocks[id] {
            let zone: Zone = point.y < (block.lowerBound + block.upperBound) / 2 ? .before : .after
            if allows(header, zone) { return Hit(slot: header, zone: zone, target: Self.target(header, zone), refusal: nil) }
            current = header.parent
        }
        return nil
    }

    /// The line whose y range holds `y` (binary search), else the nearest.
    private func line(at y: CGFloat) -> [Slot]? {
        guard !lines.isEmpty else { return nil }
        var low = 0, high = lines.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if (lines[mid].first?.frame.minY ?? 0) <= y { low = mid } else { high = mid - 1 }
        }
        return lines[low]
    }

    /// The tile under `x` on a flowed line (binary search), else the line's only slot.
    private static func slot(in line: [Slot], x: CGFloat) -> Slot {
        guard line.count > 1 else { return line[0] }
        var low = 0, high = line.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if line[mid].frame.minX <= x { low = mid } else { high = mid - 1 }
        }
        return line[low]
    }

    static func zone(_ slot: Slot, _ point: CGPoint) -> Zone {
        let frame = slot.frame
        switch slot.kind {
        case .section, .emptyGroup:
            return .into
        case .tile:
            return point.x < frame.midX ? .before : .after
        case .group:
            let fraction = frame.height > 0 ? (point.y - frame.minY) / frame.height : 0.5
            if intoBand.contains(fraction) { return .into }
            return fraction < intoBand.lowerBound ? .before : .after
        case .row:
            return point.y < frame.midY ? .before : .after
        }
    }

    /// The move a drop at `zone` of `slot` makes.
    static func target(_ slot: Slot, _ zone: Zone) -> SidebarDocTarget {
        guard let item = slot.item, slot.kind != .section else { return SidebarDocTarget(section: slot.section, index: 0) }
        switch zone {
        case .before: return SidebarDocTarget(section: slot.section, parent: slot.parent, before: item)
        case .after: return SidebarDocTarget(section: slot.section, parent: slot.parent, after: item)
        case .into: return SidebarDocTarget(section: slot.section, parent: item)
        }
    }

    /// The base y a dragged list card's drop is hit-tested at, from the card's
    /// `top` and `bottom` (display coordinates, the gap open at `gapY`); nil
    /// keeps `current`.
    ///
    /// The midpoint rule (Lawrence 2026-10-20): moving up, the card's top
    /// decides, so it goes before the row above as soon as its top passes
    /// that row's middle; moving down, its bottom decides, so it goes after
    /// the row below as soon as its bottom passes that row's middle. Rows of
    /// any height, a group's members and listed items take the same rule.
    /// A drag that turns back (`reversing`: the last change came the other
    /// way) must pass the middle by ``hysteresis(for:)``
    /// of the row it crosses before the drop changes, so a pointer held at
    /// the threshold never flips the rows.
    public func edgeY(top: CGFloat, bottom: CGFloat, x: CGFloat, movingUp: Bool, gapY: CGFloat?, gapHeight: CGFloat,
                      current: SidebarDocTarget?, reversing: Bool) -> CGFloat? {
        let y = Self.baseY(displayY: movingUp ? top : bottom, gapY: gapY, gapHeight: gapHeight)
        guard reversing, let current, let candidate = hit(CGPoint(x: x, y: y)), candidate.target != current else { return y }
        let margin = Self.hysteresis(for: candidate.slot.frame.height)
        return hit(CGPoint(x: x, y: movingUp ? y + margin : y - margin))?.target == candidate.target ? y : nil
    }

    /// The share of a row's height a turning-back row drag must pass its middle by (``edgeY``).
    static let hysteresisFraction: CGFloat = 0.2
    /// The most a turning-back row drag must pass a row's middle by, in points.
    static let maxHysteresis: CGFloat = 8

    /// The margin past a row's middle that turns a row drag back, for a row `height` tall.
    static func hysteresis(for height: CGFloat) -> CGFloat {
        min(maxHysteresis, max(0, height) * hysteresisFraction)
    }

    /// The display y of `y` in a layout drawn without the open gap
    /// (`gapY`, `gapHeight`): rows below the gap were pushed down by it.
    public static func baseY(displayY y: CGFloat, gapY: CGFloat?, gapHeight: CGFloat) -> CGFloat {
        guard let gapY, y >= gapY else { return y }
        return max(gapY, y - gapHeight)
    }
}
