import CmuxNextCompat
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
    ///
    /// Memory safety: `pointer` is the mirror `make()` created and the
    /// owning `SidebarMirror`'s deinit frees once, so it is live for every
    /// call; a typed reply stays valid until the next typed call
    /// (cmux_layout_reducer_ffi.h), and `call` reads each before it returns.
    // crash-allow: the handle is never shared; only the owning mirror (main actor) and its deinit touch it.
    @safe private nonisolated struct Handle: @unchecked Sendable { let pointer: OpaquePointer }
    private let owned: Handle
    // SAFETY: the live handle (see Handle).
    private var handle: OpaquePointer { unsafe owned.pointer }

    private init(handle: OpaquePointer) {
        // SAFETY: takes ownership of the new handle `make()` got; deinit frees it.
        owned = unsafe Handle(pointer: handle)
    }

    /// This build links the mirror FFI (rows come from the sidebar document when the daemon serves it).
    public static let isLinked = true

    public static func make() -> SidebarMirror? {
        // SAFETY: the mirror returns a new handle or NULL; the new SidebarMirror owns it.
        guard let handle = unsafe cmux_sidebar_mirror_new() else { return nil }
        return unsafe SidebarMirror(handle: handle)
    }

    nonisolated deinit {
        // SAFETY: frees the handle init took, exactly once; nothing uses it after.
        unsafe cmux_sidebar_mirror_free(owned.pointer)
    }

    /// One typed call: JSON in, a reply the mirror owns (valid until the next typed call), read at once. The
    /// caller vouches that `entry` is a typed entry returning a `Typed` reply and that `read` copies what it
    /// keeps out of the reply's buffers.
    @unsafe
    private func call<Typed, Value>(_ name: String, _ entry: (OpaquePointer?, UnsafePointer<UInt8>?, Int) -> UnsafePointer<Typed>?,
                                    _ request: Data, _ read: (Typed) -> Value?) -> Value? {
        Self.calls[name, default: 0] += 1
        // SAFETY: `input` views the request's request.count bytes, valid for the closure; the handle is live (see
        // Handle), and the reply is read here, before any other call on the handle.
        return unsafe request.withUnsafeBytes { input in
            unsafe entry(handle, input.bindMemory(to: UInt8.self).baseAddress, request.count).flatMap { unsafe read($0.pointee) }
        }
    }

    // SAFETY (the five calls below): each entry returns the reply type its reader takes, and each reader copies
    // the reply's buffers before it returns.
    private func load(raw: Data) -> Reply? { unsafe call("load", cmux_sidebar_mirror_load_typed, raw, Reply.init) }
    private func applyBatch(raw: Data) -> Reply? { unsafe call("batch", cmux_sidebar_mirror_apply_batch_typed, raw, Reply.init) }
    private func applyIntent(raw: Data) -> Reply? { unsafe call("intent", cmux_sidebar_mirror_apply_intent_typed, raw, Reply.init) }
    private func view(raw: Data) -> [SidebarDocRow]? { unsafe call("view", cmux_sidebar_mirror_view_typed, raw, Self.rows) }
    private func dragBegin(raw: Data) -> [String: SidebarDocAcceptance]? {
        unsafe call("drag_begin", cmux_sidebar_mirror_drag_begin_typed, raw, Self.acceptance)
    }

    /// The `count` elements at `start` as an array (none for nil or 0). The
    /// caller vouches that `start` is nil or readable for `count` elements.
    @unsafe
    private nonisolated static func copy<Element>(_ start: UnsafePointer<Element>?, count: Int) -> [Element] {
        // SAFETY: the caller's contract: `start` is nil or points to `count` readable elements.
        guard let start = unsafe start, count > 0 else { return [] }
        return unsafe Array(UnsafeBufferPointer(start: start, count: count))
    }

    /// The reply's strings (`CmuxSidebarStrings`): string i is bytes[offsets[i] ..< offsets[i + 1]]. The caller
    /// vouches that the table is a live reply's; a string whose offsets fall outside its bytes reads as "".
    @unsafe
    private static func strings(_ table: CmuxSidebarStrings) -> [String] {
        // SAFETY: the caller's contract: `offsets` holds count + 1 entries, and `bytes` the offsets[count] bytes
        // they index (cmux_layout_reducer_ffi.h); both are copied here.
        let offsets = unsafe copy(table.offsets, count: table.count > 0 ? Int(table.count) + 1 : 0)
        guard let end = offsets.last else { return [] }
        let bytes = unsafe copy(table.bytes, count: Int(end))
        return (0..<offsets.count - 1).map { index -> String in
            let start = Int(offsets[index]), end = Int(offsets[index + 1])
            guard start <= end, end <= bytes.count else { return "" }
            return String(decoding: bytes[start..<end], as: UTF8.self)
        }
    }

    /// `CMUX_SIDEBAR_NONE` (and an out-of-range index) is nil.
    private static func string(_ strings: [String], _ index: UInt32) -> String? {
        index == UInt32.max || Int(index) >= strings.count ? nil : strings[Int(index)]
    }

    /// The caller vouches that `reply` is the live reply of the call just made.
    @unsafe
    private static func rows(_ reply: CmuxSidebarRows) -> [SidebarDocRow]? {
        // SAFETY: the caller's contract: the reply's rows hold row_count rows and its string table is live; both
        // are copied here, before the reply can be replaced.
        guard unsafe reply.ok != 0 else { return nil }
        let strings = unsafe strings(reply.strings)
        let rows = unsafe copy(reply.rows, count: Int(reply.row_count))
        let text = { (index: UInt32) in string(strings, index) }
        return rows.compactMap { row in
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

    /// The caller vouches that `reply` is the live reply of the call just made.
    @unsafe
    private static func acceptance(_ reply: CmuxSidebarAcceptanceTable) -> [String: SidebarDocAcceptance]? {
        // SAFETY: the caller's contract: the reply's entries hold count entries and its string table is live; both
        // are copied here, before the reply can be replaced.
        guard unsafe reply.ok != 0 else { return nil }
        let strings = unsafe strings(reply.strings)
        let entries = unsafe copy(reply.entries, count: Int(reply.count))
        var table: [String: SidebarDocAcceptance] = [:]
        table.reserveCapacity(entries.count)
        for entry in entries {
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
        /// The caller vouches that `reply` is the live reply of the call just made.
        @unsafe
        init(_ reply: CmuxSidebarReply) {
            // SAFETY: the caller's contract: refusal and ops are nil or hold refusal_len and ops_len bytes; both are
            // copied here, and the rest are scalar fields of the local copy `reply`.
            ok = unsafe reply.ok != 0 && reply.refetch == 0
            stale = unsafe reply.stale != 0
            let refusalBytes = unsafe SidebarMirror.copy(reply.refusal, count: reply.refusal_len)
            if !refusalBytes.isEmpty { refusal = String(decoding: refusalBytes, as: UTF8.self) }
            revision = unsafe reply.has_revision != 0 ? reply.revision : nil
            let opsBytes = unsafe SidebarMirror.copy(reply.ops, count: reply.ops_len)
            if !opsBytes.isEmpty { ops = Data(opsBytes) }
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
        try c.encode(try JSONDecoder().blockingDecode(SidebarDocWire.AnyJSONValue.self, from: ops), forKey: .ops)
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
