public import Foundation
#if CMUX_SIDEBAR_MIRROR_FFI
import CCmuxLayoutReducerFFI
#endif

/// The client's copy of the sidebar document, run by the same Rust reducer
/// the daemon runs (cmux-layout-reducer-ffi `cmux_sidebar_mirror_*`): the
/// confirmed document plus the pending intents. Swift calls it only on
/// load, an echoed batch, an intent, a structural view rebuild and a drag's
/// begin; never per mouse-move and never per status tick (CONTRACT.md).
///
/// `make()` is nil while the linked app FFI has no mirror (the build flag
/// `CMUX_SIDEBAR_MIRROR_FFI` comes with the FFI pin that has it); the
/// sidebar then keeps its older path.
@MainActor
public final class SidebarMirror {
    /// FFI calls this process made, by entry (`load`, `batch`, `intent`,
    /// `view`, `drag_begin`), for `debug.sidebar_rows`: a drag adds one
    /// `drag_begin` and one `intent`, nothing per mouse-move.
    public private(set) static var calls: [String: Int] = [:]

    /// Why an intent was not applied (`cross_machine`, `provider_owned`, ...).
    public struct Refusal: Error, Hashable, Sendable {
        public var code: String
    }

    #if CMUX_SIDEBAR_MIRROR_FFI
    /// The mirror handle. Used on the main actor only; the deinit frees it once nothing else can.
    // crash-allow: the handle is never shared; only the owning mirror (main actor) and its deinit touch it.
    private nonisolated struct Handle: @unchecked Sendable { let pointer: OpaquePointer }
    private let owned: Handle
    private var handle: OpaquePointer { owned.pointer }

    private init(handle: OpaquePointer) {
        owned = Handle(pointer: handle)
    }

    /// This build links the mirror FFI (rows come from the sidebar document when the daemon serves it).
    public static let isLinked = true

    public static func make() -> SidebarMirror? {
        guard let handle = cmux_sidebar_mirror_new() else { return nil }
        return SidebarMirror(handle: handle)
    }

    nonisolated deinit {
        cmux_sidebar_mirror_free(owned.pointer)
    }

    /// One typed call: JSON in, a reply the mirror owns (valid until the next typed call), read at once.
    private func call<Typed, Value>(_ name: String, _ entry: (OpaquePointer?, UnsafePointer<UInt8>?, Int) -> UnsafePointer<Typed>?,
                                    _ request: Data, _ read: (Typed) -> Value?) -> Value? {
        Self.calls[name, default: 0] += 1
        return request.withUnsafeBytes { input in
            entry(handle, input.bindMemory(to: UInt8.self).baseAddress, request.count).flatMap { read($0.pointee) }
        }
    }

    private func load(raw: Data) -> Reply? { call("load", cmux_sidebar_mirror_load_typed, raw, Reply.init) }
    private func applyBatch(raw: Data) -> Reply? { call("batch", cmux_sidebar_mirror_apply_batch_typed, raw, Reply.init) }
    private func applyIntent(raw: Data) -> Reply? { call("intent", cmux_sidebar_mirror_apply_intent_typed, raw, Reply.init) }
    private func view(raw: Data) -> [SidebarDocRow]? { call("view", cmux_sidebar_mirror_view_typed, raw, Self.rows) }
    private func dragBegin(raw: Data) -> [String: SidebarDocAcceptance]? {
        call("drag_begin", cmux_sidebar_mirror_drag_begin_typed, raw, Self.acceptance)
    }

    /// The reply's strings (`CmuxSidebarStrings`): string i is bytes[offsets[i] ..< offsets[i + 1]].
    private static func strings(_ table: CmuxSidebarStrings) -> [String] {
        guard table.count > 0, let bytes = table.bytes, let offsets = table.offsets else { return [] }
        return (0..<Int(table.count)).map { index in
            let start = Int(offsets[index])
            return String(decoding: UnsafeBufferPointer(start: bytes + start, count: Int(offsets[index + 1]) - start), as: UTF8.self)
        }
    }

    /// `CMUX_SIDEBAR_NONE` (and an out-of-range index) is nil.
    private static func string(_ strings: [String], _ index: UInt32) -> String? {
        index == UInt32.max || Int(index) >= strings.count ? nil : strings[Int(index)]
    }

    private static func rows(_ reply: CmuxSidebarRows) -> [SidebarDocRow]? {
        guard reply.ok != 0 else { return nil }
        let strings = strings(reply.strings)
        let text = { (index: UInt32) in string(strings, index) }
        return UnsafeBufferPointer(start: reply.rows, count: Int(reply.row_count)).compactMap { row in
            guard let key = text(row.key), let section = text(row.section) else { return nil }
            var ref: SidebarDocWorkspaceRef?
            if let session = text(row.ref_session), let workspace = text(row.ref_workspace) {
                ref = SidebarDocWorkspaceRef(sessionID: session, workspaceID: workspace)
            }
            return SidebarDocRow(key: key, kind: text(row.kind) ?? "item", section: section, parent: text(row.parent), depth: Int(row.depth),
                                 // CMUX_SIDEBAR_ROW_DIMMED 1, CMUX_SIDEBAR_ROW_ARCHIVED 4.
                                 item: text(row.item), dimmed: row.flags & 1 != 0, archived: row.flags & 4 != 0, ref: ref)
        }
    }

    private static func acceptance(_ reply: CmuxSidebarAcceptanceTable) -> [String: SidebarDocAcceptance]? {
        guard reply.ok != 0 else { return nil }
        let strings = strings(reply.strings)
        var table: [String: SidebarDocAcceptance] = [:]
        table.reserveCapacity(Int(reply.count))
        for entry in UnsafeBufferPointer(start: reply.entries, count: Int(reply.count)) {
            guard let key = string(strings, entry.key) else { continue }
            // CMUX_SIDEBAR_ACCEPT_BEFORE 1, _INTO 2, _AFTER 4.
            table[key] = SidebarDocAcceptance(before: entry.flags & 1 != 0, into: entry.flags & 2 != 0, after: entry.flags & 4 != 0,
                                              refusal: string(strings, entry.refusal))
        }
        return table
    }
    #else
    public static let isLinked = false
    public static func make() -> SidebarMirror? { nil }

    private func load(raw: Data) -> Reply? { nil }
    private func applyBatch(raw: Data) -> Reply? { nil }
    private func applyIntent(raw: Data) -> Reply? { nil }
    private func view(raw: Data) -> [SidebarDocRow]? { nil }
    private func dragBegin(raw: Data) -> [String: SidebarDocAcceptance]? { nil }
    #endif

    // MARK: Calls

    /// Replaces the confirmed document with a `sidebar.get` reply; pending
    /// intents the new document refuses are dropped.
    @discardableResult
    public func load(_ document: Data) -> Bool { load(raw: document)?.ok ?? false }

    /// What a batch did to the mirror.
    public enum BatchOutcome: Hashable, Sendable {
        /// Applied: the confirmed revision now (an intent with the batch's key is no longer pending).
        case applied(revision: UInt64?)
        /// Older than the confirmed document: nothing changed.
        case stale
        /// A revision was skipped, or the batch could not be read: fetch the document again.
        case refetch
    }

    /// Applies one echoed batch (`{revision, previous_revision?, idempotency_key?, changes}`).
    public func apply(batch: Data) -> BatchOutcome {
        guard let reply = applyBatch(raw: batch), reply.ok else { return .refetch }
        return reply.stale ? .stale : .applied(revision: reply.revision)
    }

    /// Drops the pending intent `key` (the daemon refused it; no batch will echo it).
    public func reject(_ key: String) {
        guard let body = try? JSONEncoder().encode(Rejected(idempotencyKey: key)) else { return }
        _ = applyBatch(raw: body)
    }

    /// Applies an intent optimistically (the daemon's reply or batch
    /// settles it) and returns its ops as the mirror stamped them (the ids it
    /// minted for added items: send these, so the echo and the inverse name
    /// the same items). Throws the reducer's refusal.
    @discardableResult
    public func apply(intent: SidebarMirrorIntent) throws -> Data? {
        guard let request = try? JSONEncoder().encode(intent), let reply = applyIntent(raw: request) else {
            throw Refusal(code: "unavailable")
        }
        guard reply.ok else { throw Refusal(code: reply.refusal ?? "unavailable") }
        return reply.ops
    }

    /// The flat rows the sidebar draws, in order (typed FFI rows: no JSON decode).
    public func rows(_ request: SidebarViewRequest) -> [SidebarDocRow]? {
        SidebarPerfCounters.timedMirror {
            guard let body = try? JSONEncoder().encode(request) else { return nil }
            return view(raw: body)
        }
    }

    /// What a drop of `items` may do next to each row, by row key (one call per drag).
    public func acceptance(dragging items: [String]) -> [String: SidebarDocAcceptance] {
        SidebarPerfCounters.timedMirror {
            guard let body = try? JSONEncoder().encode(["items": items]) else { return [:] }
            return dragBegin(raw: body) ?? [:]
        }
    }

    /// A reply's common fields (`CmuxSidebarReply`): `ok` (and not `refetch`), `stale`, `refusal` (or "error"), `revision`.
    private struct Reply {
        var ok = false, stale = false
        var refusal: String?
        var revision: UInt64?
        /// `apply_intent`'s stamped ops (a JSON array), sent on as bytes.
        var ops: Data?

        #if CMUX_SIDEBAR_MIRROR_FFI
        init(_ reply: CmuxSidebarReply) {
            ok = reply.ok != 0 && reply.refetch == 0
            stale = reply.stale != 0
            if reply.refusal_len > 0, let bytes = reply.refusal {
                refusal = String(decoding: UnsafeBufferPointer(start: bytes, count: reply.refusal_len), as: UTF8.self)
            }
            revision = reply.has_revision != 0 ? reply.revision : nil
            if reply.ops_len > 0, let bytes = reply.ops { ops = Data(bytes: bytes, count: reply.ops_len) }
        }
        #endif
    }

    private struct Rejected: Encodable {
        var idempotencyKey: String
        var rejected = true
        enum CodingKeys: String, CodingKey { case rejected; case idempotencyKey = "idempotency_key" }
    }

}

/// An optimistic intent for the mirror, `{idempotency_key, ops:[op]}`: a
/// move, a pin or unpin (the reducer's `move`, `pin`, `unpin` ops), or the
/// inverse ops the daemon returned (undo, redo).
public nonisolated struct SidebarMirrorIntent: Hashable, Sendable, Encodable {
    /// The ops as JSON (an array).
    public var ops: Data
    public var idempotencyKey: String

    public static func move(_ items: [String], to target: SidebarDocTarget, key: String) -> SidebarMirrorIntent {
        op(Op(op: "move", items: items, to: target), key: key)
    }

    public static func pin(_ items: [String], key: String) -> SidebarMirrorIntent { op(Op(op: "pin", items: items), key: key) }
    public static func unpin(_ items: [String], key: String) -> SidebarMirrorIntent { op(Op(op: "unpin", items: items), key: key) }

    public static func apply(_ ops: Data, key: String) -> SidebarMirrorIntent { SidebarMirrorIntent(ops: ops, idempotencyKey: key) }

    private static func op(_ op: Op, key: String) -> SidebarMirrorIntent {
        SidebarMirrorIntent(ops: (try? JSONEncoder().encode([op])) ?? Data("[]".utf8), idempotencyKey: key)
    }

    private struct Op: Encodable {
        var op: String
        var items: [String]
        var to: SidebarDocTarget?
    }

    enum CodingKeys: String, CodingKey {
        case ops
        case idempotencyKey = "idempotency_key"
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(try JSONDecoder().decode(SidebarDocWire.AnyJSONValue.self, from: ops), forKey: .ops)
        try c.encode(idempotencyKey, forKey: .idempotencyKey)
    }
}

/// `view`'s input: the live workspaces (the doc keeps closed ones only
/// where its section keeps them), the filter text and the collapsed groups
/// (empty: every group lists its members; the list folds them itself). The
/// window's own membership stays the App's (`SidebarSection.filter`).
public nonisolated struct SidebarViewRequest: Hashable, Sendable, Encodable {
    public var live: [SidebarDocWorkspaceRef]
    public var filter: String?
    public var collapsed: [String]

    public init(live: [SidebarDocWorkspaceRef], filter: String? = nil, collapsed: [String] = []) {
        self.live = live
        self.filter = filter
        self.collapsed = collapsed
    }
}
