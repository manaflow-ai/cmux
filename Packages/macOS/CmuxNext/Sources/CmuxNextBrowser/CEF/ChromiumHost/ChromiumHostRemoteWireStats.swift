/// The attached Chromium Host's control channel counters, as the remote shim keeps them
/// (`cmux_remote_shim_get_stats`, `cmux_remote_shim_stats` in ChromiumHost/client/remote_shim_runtime.h):
/// `debug.cef` `host_wire` (task 224 of plans/cmux-next/chrome-parity/p01-process.md).
public nonisolated struct ChromiumHostRemoteWireStats: Equatable, Sendable {
    /// Posts while the channel's outbox or the attach queue was over quota (256 KiB or 4,096 waiting).
    public var quotaExcess: UInt64
    /// Waiting state ops replaced by a newer one.
    public var coalesced: UInt64
    /// Frames the socket has not taken yet.
    public var pendingMessages: UInt64
    /// Mirror reads with no host attached.
    public var readsUnattached: UInt64
    /// Ops not sent: over a frame bound, or no host.
    public var unsendable: UInt64
    /// REPLY frames with no reply callback.
    public var repliesUnhandled: UInt64
    /// Optional ops refused: the host's HELLO did not list the export.
    public var unsupported: UInt64

    /// The struct's `uint64_t` fields, in declaration order.
    static let fieldCount = 7

    /// The counters from `fields`, the C struct's words in declaration order; nil for another count.
    init?(fields: [UInt64]) {
        guard fields.count == Self.fieldCount else { return nil }
        quotaExcess = fields[0]
        coalesced = fields[1]
        pendingMessages = fields[2]
        readsUnattached = fields[3]
        unsendable = fields[4]
        repliesUnhandled = fields[5]
        unsupported = fields[6]
    }

    /// The counters under their `debug.cef` names.
    public var report: [String: Double] {
        ["quota_excess": Double(quotaExcess), "coalesced": Double(coalesced), "pending_messages": Double(pendingMessages),
         "reads_unattached": Double(readsUnattached), "unsendable": Double(unsendable),
         "replies_unhandled": Double(repliesUnhandled), "unsupported": Double(unsupported)]
    }
}

extension CEFRemoteShim {
    typealias GetStatsFn = @convention(c) (UnsafeMutableRawPointer?) -> Void

    /// The remote shim's counters now (main thread, as the export asserts); nil when the dylib has no
    /// `cmux_remote_shim_get_stats`.
    func wireStats() -> ChromiumHostRemoteWireStats? {
        guard let pointer = unsafe symbol("cmux_remote_shim_get_stats") else { return nil }
        // SAFETY: the symbol is the export of remote_shim_runtime.h, `void (cmux_remote_shim_stats*)`, from the
        // remote dylib, whose handle is never closed.
        let getStats = unsafe unsafeBitCast(pointer, to: GetStatsFn.self)
        var fields = [UInt64](repeating: 0, count: ChromiumHostRemoteWireStats.fieldCount)
        // SAFETY: `cmux_remote_shim_stats` is `fieldCount` uint64_t fields and nothing else, so the array's
        // buffer has its size and alignment; the export writes the struct once, during the call.
        unsafe fields.withUnsafeMutableBytes { buffer in unsafe getStats(buffer.baseAddress) }
        return ChromiumHostRemoteWireStats(fields: fields)
    }
}

extension CEFEngine {
    /// `debug.cef` `host_wire`: the attached host's control channel counters; nil in process, while no
    /// host is attached, or with a remote dylib that does not export them.
    public var hostWireStats: ChromiumHostRemoteWireStats? {
        CEFRuntime.shared.hostStart?.remote?.wireStats()
    }
}
