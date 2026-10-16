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

    private typealias Entry = (OpaquePointer?, UnsafePointer<UInt8>?, Int) -> UnsafeMutablePointer<CChar>?

    /// One call: JSON in, the reply's JSON out (a string the FFI allocates and this frees).
    private func call(_ name: String, _ entry: Entry, _ request: Data) -> Data? {
        Self.calls[name, default: 0] += 1
        let reply = request.withUnsafeBytes { input in entry(handle, input.bindMemory(to: UInt8.self).baseAddress, request.count) }
        guard let reply else { return nil }
        defer { cmux_sidebar_mirror_string_free(reply) }
        return Data(String(cString: reply).utf8)
    }

    private func load(raw: Data) -> Data? { call("load", cmux_sidebar_mirror_load, raw) }
    private func applyBatch(raw: Data) -> Data? { call("batch", cmux_sidebar_mirror_apply_batch, raw) }
    private func applyIntent(raw: Data) -> Data? { call("intent", cmux_sidebar_mirror_apply_intent, raw) }
    private func view(raw: Data) -> Data? { call("view", cmux_sidebar_mirror_view, raw) }
    private func dragBegin(raw: Data) -> Data? { call("drag_begin", cmux_sidebar_mirror_drag_begin, raw) }
    #else
    public static let isLinked = false
    public static func make() -> SidebarMirror? { nil }

    private func load(raw: Data) -> Data? { nil }
    private func applyBatch(raw: Data) -> Data? { nil }
    private func applyIntent(raw: Data) -> Data? { nil }
    private func view(raw: Data) -> Data? { nil }
    private func dragBegin(raw: Data) -> Data? { nil }
    #endif

    // MARK: Calls

    /// Replaces the confirmed document with a `sidebar.get` reply; pending
    /// intents the new document refuses are dropped.
    @discardableResult
    public func load(_ document: Data) -> Bool { load(raw: document).map(Reply.init).map(\.ok) ?? false }

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
        guard let reply = applyBatch(raw: batch).map(Reply.init), reply.ok else { return .refetch }
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
        let decoded = Reply(reply)
        guard decoded.ok else { throw Refusal(code: decoded.refusal ?? "unavailable") }
        return decoded.ops
    }

    // Main-actor baseline (chief-approved raise, 3 hits: rows, acceptance, Reply.init): structural rebuild /
    // drag start only, not per tick; JSON decode of Rust mirror view; removal bead cx-x5jpp; expires 2026-10-20.
    /// The flat rows the sidebar draws, in order.
    public func rows(_ request: SidebarViewRequest) -> [SidebarDocRow]? {
        SidebarPerfCounters.timedMirror {
            guard let body = try? JSONEncoder().encode(request), let reply = view(raw: body) else { return nil }
            return try? JSONDecoder().decode([SidebarDocRow].self, from: reply) // an array (CONTRACT amendments)
        }
    }

    /// What a drop of `items` may do next to each row, by row key (one call per drag).
    public func acceptance(dragging items: [String]) -> [String: SidebarDocAcceptance] {
        SidebarPerfCounters.timedMirror {
            guard let body = try? JSONEncoder().encode(["items": items]), let reply = dragBegin(raw: body) else { return [:] }
            return (try? JSONDecoder().decode([String: SidebarDocAcceptance].self, from: reply)) ?? [:] // the table itself
        }
    }

    /// A reply's common fields: `ok`, `stale`, `refetch`, `refusal`, `revision`, `error`.
    private struct Reply {
        var ok = false, stale = false
        var refusal: String?
        var revision: UInt64?
        /// `apply_intent`'s stamped ops (a JSON array).
        var ops: Data?

        init(_ data: Data) {
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            ops = (object["ops"] as? [Any]).flatMap { try? JSONSerialization.data(withJSONObject: $0) }
            ok = object["ok"] as? Bool == true && object["refetch"] as? Bool != true
            stale = object["stale"] as? Bool == true
            refusal = object["refusal"] as? String ?? (object["error"] != nil ? "error" : nil)
            // A decimal string (the contract), or a number from an older FFI.
            revision = (object["revision"] as? String).flatMap { UInt64($0, radix: 10) } ?? (object["revision"] as? NSNumber)?.uint64Value
        }
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
