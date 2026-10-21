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
            guard let group = slot.kind == .group ? slot.key : slot.parent, headers[group] != nil else { continue }
            let range = slot.frame.minY...slot.frame.maxY
            blocks[group] = blocks[group].map { min($0.lowerBound, range.lowerBound)...max($0.upperBound, range.upperBound) } ?? range
        }
        groupHeaders = headers
        groupBlocks = blocks
    }

    /// The slot under `point` (or the nearest one above or below the
    /// slots), its zone and the move a drop there makes.
    ///
    /// A drop that cannot go into a group (a dragged group: groups do not
    /// nest; a workspace of another machine) goes before or after the whole
    /// group instead, by which half of the group's block holds `point`: over
    /// its header or any of its member rows. Without this, a dragged group
    /// found a slot only on the thin top and bottom bands of each header.
    public func hit(_ point: CGPoint) -> Hit? {
        guard let line = line(at: point.y) else { return nil }
        let slot = Self.slot(in: line, x: point.x)
        if slot.kind == .group, !allows(slot, .into), let around = around(group: slot.key, point) { return around }
        let zone = Self.zone(slot, point)
        if allows(slot, zone) { return Hit(slot: slot, zone: zone, target: Self.target(slot, zone), refusal: nil) }
        if let parent = slot.parent, let around = around(group: parent, point) { return around }
        let accepted = acceptance[slot.key] ?? slot.item.flatMap { acceptance[$0] }
        return Hit(slot: slot, zone: zone, target: nil, refusal: accepted?.refusal ?? "refused")
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

    /// A drop before (upper half of the block) or after (lower half) the whole group `group`, if accepted there.
    private func around(group: String, _ point: CGPoint) -> Hit? {
        guard let header = groupHeaders[group], let block = groupBlocks[group] else { return nil }
        let zone: Zone = point.y < (block.lowerBound + block.upperBound) / 2 ? .before : .after
        guard allows(header, zone) else { return nil }
        return Hit(slot: header, zone: zone, target: Self.target(header, zone), refusal: nil)
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
        case .section:
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
    /// way) must pass the middle by `SidebarGroupReorder.hysteresis(for:)`
    /// of the row it crosses before the drop changes, so a pointer held at
    /// the threshold never flips the rows.
    public func edgeY(top: CGFloat, bottom: CGFloat, x: CGFloat, movingUp: Bool, gapY: CGFloat?, gapHeight: CGFloat,
                      current: SidebarDocTarget?, reversing: Bool) -> CGFloat? {
        let y = Self.baseY(displayY: movingUp ? top : bottom, gapY: gapY, gapHeight: gapHeight)
        guard reversing, let current, let candidate = hit(CGPoint(x: x, y: y)), candidate.target != current else { return y }
        let margin = SidebarGroupReorder.hysteresis(for: candidate.slot.frame.height)
        return hit(CGPoint(x: x, y: movingUp ? y + margin : y - margin))?.target == candidate.target ? y : nil
    }

    /// The display y of `y` in a layout drawn without the open gap
    /// (`gapY`, `gapHeight`): rows below the gap were pushed down by it.
    public static func baseY(displayY y: CGFloat, gapY: CGFloat?, gapHeight: CGFloat) -> CGFloat {
        guard let gapY, y >= gapY else { return y }
        return max(gapY, y - gapHeight)
    }
}
