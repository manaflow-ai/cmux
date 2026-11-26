import CmuxNextCompat
public import CoreGraphics
import Foundation

/// The drag engine's per-mouse-move work (sidebar-v2 S5) over the slots the sidebar drew and the acceptance
/// table the reducer gave once at the drag's begin (`SidebarMirror.acceptance`). The drop is one move
/// (`SidebarDocTarget`).
///
/// The rules are Rust's: cmux-layout-reducer `sidebar_drop_geometry` behind the JSON ops `sidebar_geometry_*`
/// (cmux-layout-reducer-ffi `sidebar_geometry.rs`). This value holds what it was made from; the first question
/// sends the slots to Rust once (``Kept``) and every question after sends only a point. Nothing here decides.
/// A reducer that does not answer (an app FFI older than the ops) finds no drop.
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
        /// A group header's slot whose group is collapsed (it may still show a kept member row under it).
        public var collapsed: Bool

        public init(key: String, item: String?, section: String, parent: String? = nil, frame: CGRect, kind: Kind,
                    collapsed: Bool = false) {
            self.key = key
            self.item = item
            self.section = section
            self.parent = parent
            self.frame = frame
            self.kind = kind
            self.collapsed = collapsed
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

    /// The slots in the order given: a hit names its slot by index into them.
    let slots: [Slot]
    let acceptance: [String: SidebarDocAcceptance]
    /// The outliner rule's indent (nested-groups prototype): at the bottom edge of a nested block the
    /// pointer's x picks the level the drop goes to. Nil keeps the y-only rule. A change sends the slots again.
    var outline: (indent: SidebarIndent, leading: CGFloat, width: CGFloat)? {
        didSet { kept = Kept() }
    }
    /// The geometry Rust keeps for this value (its copies share it).
    private var kept = Kept()

    /// `slots` in any order; `acceptance` from the drag's begin (empty:
    /// every place is accepted, as for a mirror without the table).
    public init(slots: [Slot], acceptance: [String: SidebarDocAcceptance]) {
        self.slots = slots
        self.acceptance = acceptance
    }

    /// The slot under `point` (or the nearest one above or below the
    /// slots), its zone and the move a drop there makes.
    ///
    /// A drop a group's rows refuse (a dragged group lands beside rows only at
    /// its own level or above, `accept.rs`; a workspace of another machine)
    /// goes before or after the whole group instead, by which half of the
    /// group's block holds `point`; an open header's bottom quarter goes before
    /// its first member; at a nested block's bottom edge the outline's x picks the level.
    public func hit(_ point: CGPoint) -> Hit? {
        ask("sidebar_geometry_hit", { Wire.Point(id: $0, x: Double(point.x), y: Double(point.y)) }, as: Wire.HitReply.self)?
            .hit.flatMap(answer)
    }

    /// A drop right before or after the slot keyed `key` (a section's slot: first in it), if accepted there.
    ///
    /// A dragged group's slots use it (`SidebarListView+GroupDrag`): the drop goes beside a whole top-level block's
    /// first row, never into a group or beside one of its members, whatever the acceptance table would take there.
    public func beside(_ key: String, after: Bool) -> Hit? {
        ask("sidebar_geometry_beside", { Wire.Beside(id: $0, key: key, after: after) }, as: Wire.HitReply.self)?
            .hit.flatMap(answer)
    }

    /// The base y a dragged list card's drop is hit-tested at, from the card's
    /// `top` and `bottom` (display coordinates, the gap open at `gapY`); nil
    /// keeps `current`.
    ///
    /// The midpoint rule (Lawrence 2026-10-20): moving up, the card's top
    /// decides; moving down, its bottom. A drag that turns back (`reversing`)
    /// must pass the middle by a margin of the row it crosses before the drop
    /// changes, so a pointer held at the threshold never flips the rows.
    public func edgeY(top: CGFloat, bottom: CGFloat, x: CGFloat, movingUp: Bool, gapY: CGFloat?, gapHeight: CGFloat,
                      current: SidebarDocTarget?, reversing: Bool) -> CGFloat? {
        let reply = ask("sidebar_geometry_edge_y", {
            Wire.Edge(id: $0, top: Double(top), bottom: Double(bottom), x: Double(x), movingUp: movingUp,
                      gapY: gapY.map(Double.init), gapHeight: Double(gapHeight), current: current, reversing: reversing)
        }, as: Wire.YReply.self)
        return reply?.y.map { CGFloat($0) }
    }

    /// The display y of `y` in a layout drawn without the open gap
    /// (`gapY`, `gapHeight`): rows below the gap were pushed down by it.
    public static func baseY(displayY y: CGFloat, gapY: CGFloat?, gapHeight: CGFloat) -> CGFloat {
        guard let gapY else { return y }
        let request = Wire.BaseY(y: Double(y), gapY: Double(gapY), gapHeight: Double(gapHeight))
        return RustSidebarClient.call("sidebar_geometry_base_y", request, as: Wire.YReply.self)?.y.map { CGFloat($0) } ?? y
    }

    /// A hit from Rust's answer: its slot by index into ``slots``.
    private func answer(_ wire: Wire.Hit) -> Hit? {
        guard slots.indices.contains(wire.slot) else { return nil }
        return Hit(slot: slots[wire.slot], zone: wire.zone.zone, target: wire.target, refusal: wire.refusal)
    }

    /// Asks the geometry Rust keeps for this value, sending the slots first when it has none (or dropped it).
    private func ask<Request: Encodable, Reply: Decodable & SidebarGeometryReply>(
        _ operation: String, _ request: (UInt64) -> Request, as: Reply.Type
    ) -> Reply? {
        for _ in 0..<2 {
            guard let id = kept.id(registering: register) else { return nil }
            guard let reply = RustSidebarClient.call(operation, request(id), as: Reply.self) else { return nil }
            guard reply.gone == true else { return reply }
            kept.forget(id)
        }
        return nil
    }

    /// Sends the slots, the acceptance table and the outline to Rust; the id it keeps them under.
    private func register() -> UInt64? {
        RustSidebarClient.call("sidebar_geometry_new", Wire.New(self), as: Wire.Registered.self)?.id
    }

    /// The id of the geometry Rust keeps for one ``SidebarDragGeometry`` value, freed with it.
    nonisolated final class Kept: Sendable {
        private let state = Mutex<UInt64?>(nil)

        /// The kept id, registering once when there is none.
        func id(registering register: () -> UInt64?) -> UInt64? {
            state.withLock { id in
                if let id { return id }
                id = register()
                return id
            }
        }

        /// Drops `id` after Rust answered that it no longer keeps it.
        func forget(_ id: UInt64) {
            state.withLock { if $0 == id { $0 = nil } }
        }

        deinit {
            guard let id = state.withLock({ $0 }) else { return }
            _ = RustSidebarClient.call("sidebar_geometry_free", Wire.Free(id: id), as: Wire.Freed.self)
        }
    }
}
