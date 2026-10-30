/// The resizes' wire in the app: the remote shim's `cmux_remote_shim_page_resize`
/// (ChromiumHost/client/remote_shim_runtime.h).
final class ChromiumHostRemoteResizeWire: ChromiumHostPageResizeWire {
    typealias ResizeFn = @convention(c) (UInt64, Int32, Int32) -> Int32

    private let resizeFn: ResizeFn

    /// Nil when the remote dylib has no `cmux_remote_shim_page_resize`.
    init?(remote: CEFRemoteShim) {
        guard let symbol = remote.symbol("cmux_remote_shim_page_resize") else { return nil }
        resizeFn = unsafeBitCast(symbol, to: ResizeFn.self)
    }

    func resize(view: UInt64, width: Int32, height: Int32) -> Bool {
        resizeFn(view, width, height) == 1
    }
}

extension CEFRuntime {
    /// Host mode's page resizes to the attached host, made on its first use; nil in process, before the
    /// attach, or with a remote dylib that has no page resize.
    func hostPageResizes() -> ChromiumHostPageResizes? {
        guard let hostStart, let remote = hostStart.remote else { return nil }
        if let resizes = hostStart.pageResizes { return resizes }
        guard let wire = ChromiumHostRemoteResizeWire(remote: remote) else { return nil }
        let resizes = ChromiumHostPageResizes(wire: wire)
        hostStart.pageResizes = resizes
        return resizes
    }
}

extension CEFEngine {
    /// `debug.cef` `host_resize`: the attached host's page resize counters (``ChromiumHostPageResizes/Stats``;
    /// `max_resize_ms` is the main-thread time of the longest one), zero before its first resize; nil in
    /// process or while no host is attached, which is how a host mode bench (cef-resize-sync-bench.py)
    /// tells that Chromium really ran in the host.
    public var hostResizeCounters: [String: Double]? {
        guard let hostStart = CEFRuntime.shared.hostStart, hostStart.remote != nil else { return nil }
        let stats = hostStart.pageResizes?.stats ?? ChromiumHostPageResizes.Stats()
        return ["resizes": Double(stats.resizes), "max_resize_ms": Double(stats.maxResizeNanoseconds) / 1e6]
    }
}
