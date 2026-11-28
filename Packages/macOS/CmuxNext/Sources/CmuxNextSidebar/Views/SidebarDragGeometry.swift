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
    }

    /// The slot under `point` (or the nearest one above or below the
    /// slots), its zone and the move a drop there makes.
    public func hit(_ point: CGPoint) -> Hit? {
        guard let line = line(at: point.y) else { return nil }
        let slot = Self.slot(in: line, x: point.x)
        let zone = Self.zone(slot, point)
        let accepted = acceptance[slot.key] ?? slot.item.flatMap { acceptance[$0] }
        let allowed = accepted.map { table in
            switch zone {
            case .before: table.before
            case .into: table.into
            case .after: table.after
            }
        } ?? (acceptance.isEmpty || slot.kind == .section) // a header the table lacks (one machine draws none) takes the drop
        guard allowed else { return Hit(slot: slot, zone: zone, target: nil, refusal: accepted?.refusal ?? "refused") }
        return Hit(slot: slot, zone: zone, target: Self.target(slot, zone), refusal: nil)
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

    /// The display y of `y` in a layout drawn without the open gap
    /// (`gapY`, `gapHeight`): rows below the gap were pushed down by it.
    public static func baseY(displayY y: CGFloat, gapY: CGFloat?, gapHeight: CGFloat) -> CGFloat {
        guard let gapY, y >= gapY else { return y }
        return max(gapY, y - gapHeight)
    }
}
