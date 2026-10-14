import Foundation
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
    /// FFI calls this process made, for `debug.sidebar_rows` (a drag is two:
    /// `drag_begin` and the drop's intent).
    public private(set) static var calls = 0

    /// Why an intent was not applied (`cross_machine`, `provider_owned`, ...).
    public struct Refusal: Error, Hashable, Sendable {
        public var code: String
    }

    #if CMUX_SIDEBAR_MIRROR_FFI
    private let handle: OpaquePointer

    private init(handle: OpaquePointer) {
        self.handle = handle
    }

    public static func make() -> SidebarMirror? {
        guard let handle = cmux_sidebar_mirror_new() else { return nil }
        return SidebarMirror(handle: handle)
    }

    deinit {
        cmux_sidebar_mirror_free(handle)
    }

    private typealias Entry = (OpaquePointer?, UnsafePointer<UInt8>?, Int, UnsafeMutablePointer<UInt8>?, Int, UnsafeMutablePointer<Int>?) -> Int32

    /// One call: `request` in, the reply's bytes out (grown once when the
    /// first buffer is too small, as `RustSidebarClient` does).
    private func call(_ entry: Entry, _ request: Data) -> Data? {
        Self.calls += 1
        var capacity = 16 * 1024
        for _ in 0..<2 {
            var output = [UInt8](repeating: 0, count: capacity)
            var length = 0
            let code = request.withUnsafeBytes { input in
                output.withUnsafeMutableBytes { out in
                    entry(handle, input.bindMemory(to: UInt8.self).baseAddress, request.count,
                          out.bindMemory(to: UInt8.self).baseAddress, out.count, &length)
                }
            }
            if code == CMUX_LAYOUT_REDUCER_ERR_BUFFER, length > capacity {
                capacity = length
                continue
            }
            guard code == CMUX_LAYOUT_REDUCER_OK, length <= capacity else { return nil }
            return Data(output.prefix(length))
        }
        return nil
    }

    private func load(raw: Data) -> Bool { call(cmux_sidebar_mirror_load, raw) != nil }
    private func applyBatch(raw: Data) -> Bool { call(cmux_sidebar_mirror_apply_batch, raw) != nil }
    private func applyIntent(raw: Data) -> Data? { call(cmux_sidebar_mirror_apply_intent, raw) }
    private func view(raw: Data) -> Data? { call(cmux_sidebar_mirror_view, raw) }
    private func dragBegin(raw: Data) -> Data? { call(cmux_sidebar_mirror_drag_begin, raw) }
    #else
    public static func make() -> SidebarMirror? { nil }

    private func load(raw: Data) -> Bool { false }
    private func applyBatch(raw: Data) -> Bool { false }
    private func applyIntent(raw: Data) -> Data? { nil }
    private func view(raw: Data) -> Data? { nil }
    private func dragBegin(raw: Data) -> Data? { nil }
    #endif

    // MARK: Calls

    /// Replaces the confirmed document with a `sidebar.get` reply; pending
    /// intents stay applied over it.
    @discardableResult
    public func load(_ document: Data) -> Bool { load(raw: document) }

    /// Applies one echoed batch; an intent with the batch's idempotency key
    /// is no longer pending.
    @discardableResult
    public func apply(batch: Data) -> Bool { applyBatch(raw: batch) }

    /// Applies an intent optimistically (the daemon's reply or batch
    /// settles it). Throws the reducer's refusal.
    public func apply(intent: SidebarMirrorIntent) throws {
        guard let request = try? JSONEncoder().encode(intent), let reply = applyIntent(raw: request) else {
            throw Refusal(code: "unavailable")
        }
        if let refusal = (try? JSONDecoder().decode(RefusalReply.self, from: reply))?.refusal { throw Refusal(code: refusal) }
    }

    /// The flat rows the sidebar draws, in order.
    public func rows(_ request: SidebarViewRequest) -> [SidebarDocRow]? {
        guard let body = try? JSONEncoder().encode(request), let reply = view(raw: body) else { return nil }
        if let rows = try? JSONDecoder().decode([SidebarDocRow].self, from: reply) { return rows }
        return (try? JSONDecoder().decode(RowsReply.self, from: reply))?.rows
    }

    /// What a drop of `items` may do next to each row, by row key (one call per drag).
    public func acceptance(dragging items: [String]) -> [String: SidebarDocAcceptance] {
        guard let body = try? JSONEncoder().encode(["items": items]), let reply = dragBegin(raw: body) else { return [:] }
        if let table = try? JSONDecoder().decode([String: SidebarDocAcceptance].self, from: reply) { return table }
        return (try? JSONDecoder().decode(AcceptanceReply.self, from: reply))?.rows ?? [:]
    }

    private struct RefusalReply: Decodable { var refusal: String? }
    private struct RowsReply: Decodable { var rows: [SidebarDocRow] }
    private struct AcceptanceReply: Decodable { var rows: [String: SidebarDocAcceptance] }
}

/// An optimistic intent for the mirror: a move (pin and unpin are moves to
/// a section's end) or a list of inverse ops (undo, redo).
public nonisolated struct SidebarMirrorIntent: Hashable, Sendable, Encodable {
    public var op: String
    public var items: [String]?
    public var to: SidebarDocTarget?
    /// `sidebar.apply`'s ops, as the daemon returned them (JSON).
    public var ops: Data?
    public var idempotencyKey: String

    public static func move(_ items: [String], to target: SidebarDocTarget, key: String) -> SidebarMirrorIntent {
        SidebarMirrorIntent(op: "move", items: items, to: target, ops: nil, idempotencyKey: key)
    }

    public static func apply(_ ops: Data, key: String) -> SidebarMirrorIntent {
        SidebarMirrorIntent(op: "apply", items: nil, to: nil, ops: ops, idempotencyKey: key)
    }

    enum CodingKeys: String, CodingKey {
        case op, items, to, ops
        case idempotencyKey = "idempotency_key"
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(op, forKey: .op)
        try c.encodeIfPresent(items, forKey: .items)
        try c.encodeIfPresent(to, forKey: .to)
        if let ops, let value = try? JSONDecoder().decode(SidebarDocWire.AnyJSONValue.self, from: ops) { try c.encode(value, forKey: .ops) }
        try c.encode(idempotencyKey, forKey: .idempotencyKey)
    }
}

/// `view`'s input: the live workspaces (the doc keeps closed ones only
/// where its section keeps them), the window's workspaces (nil: all), the
/// filter text and the collapsed groups.
public nonisolated struct SidebarViewRequest: Hashable, Sendable, Encodable {
    public var live: [SidebarDocWorkspaceRef]
    public var window: [SidebarDocWorkspaceRef]?
    public var filter: String?
    public var collapsed: [String]

    public init(live: [SidebarDocWorkspaceRef], window: [SidebarDocWorkspaceRef]? = nil, filter: String? = nil, collapsed: [String] = []) {
        self.live = live
        self.window = window
        self.filter = filter
        self.collapsed = collapsed
    }
}
