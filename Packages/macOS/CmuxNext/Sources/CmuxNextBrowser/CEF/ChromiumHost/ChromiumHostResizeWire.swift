import CmuxNextSharedRegionC
import CmuxNextWakeups
import Darwin

/// The resizes' wire in the app: the remote shim's `cmux_remote_shim_page_resize`
/// (ChromiumHost/client/remote_shim_runtime.h), answered through the runtime's replies
/// (``CEFRuntime/whenSettled(_:label:timeout:then:)``).
final class ChromiumHostRemoteResizeWire: ChromiumHostPageResizeWire {
    typealias ResizeFn = @convention(c) (UInt64, Int32, Int32, Int32, UInt32, UInt32) -> Int32

    /// `cmux_remote_page_resize_result`.
    private static let unfenced: Int32 = 1
    private static let fenced: Int32 = 2

    private weak var runtime: CEFRuntime?
    private let resizeFn: ResizeFn

    /// Nil when the remote dylib has no `cmux_remote_shim_page_resize`.
    init?(runtime: CEFRuntime, remote: CEFRemoteShim) {
        guard let symbol = remote.symbol("cmux_remote_shim_page_resize") else { return nil }
        self.runtime = runtime
        resizeFn = unsafeBitCast(symbol, to: ResizeFn.self)
    }

    func resize(view: UInt64, browser: Int32, width: Int32, height: Int32, fence: mach_port_t,
                deadlineFrames: UInt32) -> ChromiumHostResizeFence.Send {
        switch resizeFn(view, browser, width, height, fence, deadlineFrames) {
        case Self.unfenced: return .unfenced
        case Self.fenced:
            guard let reply = runtime?.hostStart?.expectReply() else { return .unfenced }
            return .fenced(reply: reply)
        default: return .notSent
        }
    }

    func whenAnswered(_ reply: UInt32, within deadline: Duration, then: @escaping (Bool?) -> Void) {
        guard let runtime else { return then(nil) }
        runtime.whenSettled(CEFShimAnswer<Int32>.later(reply), label: "resize fence", timeout: deadline) { result in
            then(try? result.get() == 1)
        }
    }
}

extension CEFRuntime {
    /// Host mode's page resizes to the attached host, made on its first use; nil in process, before the
    /// attach, or with a remote dylib that has no page resize.
    func hostPageResizes() -> ChromiumHostResizeFence? {
        guard let hostStart, let remote = hostStart.remote else { return nil }
        if let resizes = hostStart.pageResizes { return resizes }
        guard let wire = ChromiumHostRemoteResizeWire(runtime: self, remote: remote) else { return nil }
        let resizes = ChromiumHostResizeFence(wire: wire, fences: hostStart.fencesResizes ? ChromiumHostContextFences() : nil,
                                              deadlines: ChromiumHostWakeUpDeadlines(wakeUps: waitDeadlines))
        hostStart.pageResizes = resizes
        return resizes
    }
}

extension CEFEngine {
    /// `debug.cef` `host_resize`: the attached host's page resize counters (``ChromiumHostResizeFence/Stats``;
    /// `max_resize_ms` is the main-thread time of the longest one, the fence's only main-thread cost), zero
    /// before its first resize; nil in process or while no host is attached, which is how a host mode bench
    /// (cef-resize-sync-bench.py) tells that Chromium really ran in the host.
    public var hostResizeCounters: [String: Double]? {
        guard let hostStart = CEFRuntime.shared.hostStart, hostStart.remote != nil else { return nil }
        let stats = hostStart.pageResizes?.stats ?? ChromiumHostResizeFence.Stats()
        return ["resizes": Double(stats.resizes), "fenced": Double(stats.fenced), "fenced_turns": Double(stats.fencedTurns),
                "joined": Double(stats.joined), "refused": Double(stats.refused), "late": Double(stats.late),
                "cut": Double(stats.cut), "max_resize_ms": Double(stats.maxResizeNanoseconds) / 1e6]
    }
}

/// A hold's cut on the main thread's deadline queue, at its own instant (a frame is under the flexible
/// placement's 36 ms).
struct ChromiumHostWakeUpDeadlines: ChromiumHostFenceDeadlines {
    let wakeUps: AlignedWakeups

    func after(_ delay: Duration, _ body: @escaping @MainActor @Sendable () -> Void) {
        wakeUps.schedule(owner: "ChromiumHostResizeFence.cut", after: delay, placement: .precise, body)
    }
}

/// The host's fence inbox: the bootstrap name the host checks its receive right in under
/// (`--resize-fence=<name>`, before its HELLO), and cmux's send right to it, looked up once after
/// the HELLO, off the main thread, as the input doorbell is (``ChromiumHostMachDoorbell``). The
/// supervisor's spawn (task 080) makes the name (``make()``), passes ``arguments`` and hands the name
/// over in ``ChromiumHostAttachment/resizeFence``.
nonisolated struct ChromiumHostResizeFenceChannel: Sendable, Equatable {
    static let argument = "--resize-fence="

    /// The bootstrap name.
    let name: String

    /// The host's argument naming it.
    var arguments: [String] { [Self.argument + name] }

    /// A fresh name for one host.
    static func make() -> ChromiumHostResizeFenceChannel {
        let token = UInt64.random(in: .min ... .max)
        return ChromiumHostResizeFenceChannel(name: "com.cmuxterm.chromium-host.fence.\(getpid()).\(String(token, radix: 16))")
    }

    /// A send right to the inbox the host checked in, 0 when none is there: one `bootstrap_look_up`
    /// (the doorbell's), a synchronous message to launchd, so never on the main thread.
    @concurrent
    func lookUp() async -> mach_port_t {
        cmux_input_ring_doorbell_look_up(name)
    }

    /// Gives the remote shim `port` (from ``lookUp()``) for the attached host's resizes; the shim
    /// owns it from here. A remote dylib without the call, or no host attached, releases it.
    @MainActor
    func hand(_ port: mach_port_t, to remote: CEFRemoteShim) {
        guard port != 0 else { return }
        typealias SetChannelFn = @convention(c) (UInt32) -> Int32
        guard let symbol = remote.symbol("cmux_remote_shim_set_resize_fence_channel") else {
            mach_port_deallocate(mach_task_self_, port)
            return
        }
        _ = unsafeBitCast(symbol, to: SetChannelFn.self)(port)
    }
}
