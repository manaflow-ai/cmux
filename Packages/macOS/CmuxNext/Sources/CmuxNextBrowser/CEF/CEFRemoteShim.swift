import Darwin
import CmuxNextCompat
import Foundation
import CmuxNextWakeups
import class CmuxSafeConcurrency.OnceContinuation
import enum CmuxSafeConcurrency.OnceContinuationError
import func CmuxSafeConcurrency.withOnceContinuation

/// `libcmux_cef_shim_remote.dylib` (task 014 of plans/cmux-next/chrome-parity/p01-process.md): the
/// in-process shim's C ABI, each export a non-blocking op to the Chromium Host, plus its wire entry
/// points. Host mode loads it instead of the in-process shim and never maps the CEF framework.
///
/// The wire entry points this side calls:
/// - `int cmux_remote_shim_attach(int ctl_fd, int in_ring_fd, int out_ring_fd, void* ctx,
///   cmux_remote_shim_hello_fn hello)`: takes the descriptors and returns 1 at once (0 refuses them
///   and calls nothing). `hello(ctx, attached, optional_exports)` then runs once on the main thread:
///   `attached` 1 after the host's hello is in the mirror cache, with the optional exports the host's
///   shim defines (newline-separated); 0 when the host ended first. As a mojo `Remote` reports its
///   peer's version once the pipe is bound (mojo/public/cpp/bindings/remote.h, `QueryVersion`).
/// - `void cmux_remote_shim_detach(void)`: releases the wire it holds (the host is gone, or never
///   said hello in time); a later attach serves the next host. A hello still pending runs with
///   `attached` 0 before detach returns, on the main thread, and never after. A second detach does nothing.
/// - `void cmux_remote_shim_set_reply(void* ctx, cmux_remote_reply_fn reply)`: where the host's REPLY
///   frames go, `reply(ctx, token, fields, length)` on the main thread; attach points it at the
///   runtime's ``CEFHostReplies`` and detach clears it.
/// - `void cmux_remote_shim_set_ended(void* ctx, cmux_remote_ended_fn ended)`: where the wire's own end
///   goes (the host closed it, a malformed frame, the quota, an IO error), `ended(ctx, reason)` on the
///   main thread after the shim dropped its awaited tokens; attach points it at the same
///   ``CEFHostReplies``, whose waits then resolve as `hostGone` in that turn (task 091), and detach
///   clears it. A detach cmux asks for is never reported.
/// - `uint32_t cmux_remote_shim_last_reply_token(void)`: the REPLY token of the async call this turn
///   just made; 0 when it sent nothing (task 018).
/// - `void cmux_remote_shim_set_input_ack(void* ctx, cmux_remote_input_ack_fn ack)`: where the host's
///   input acks go, `ack(ctx, browser, kind, seq)` on the main thread (task 042); optional.
/// - `uint32_t cmux_remote_shim_order_input(uint32_t* ctl_seq)`: the input seq and control seq of the
///   next ring frame (task 092); 0 with no host attached; optional.
/// - `void cmux_remote_shim_set_host_watch(void* ctx, cmux_remote_host_watch_fn watch)`: where the host
///   watch goes, `watch(ctx, event, a, b)` on the main thread: input waiting for the host's dispatch,
///   its progress and its end, and the host's UI hangs. Optional: a remote shim
///   without it has no busy banner.
///
/// Immutable C function pointers and a `dlsym` lookup over a handle that is never closed.
@safe
// crash-allow: every stored property is a let (C function pointers, a dlsym closure over a dlopen handle never closed; dlsym is thread-safe); nothing mutates after make, as in CEFShimLibrary.
nonisolated struct CEFRemoteShim: @unchecked Sendable {
    typealias HelloFn = @convention(c) (UnsafeMutableRawPointer?, Int32, UnsafePointer<CChar>?) -> Void
    typealias AttachFn = @convention(c) (Int32, Int32, Int32, UnsafeMutableRawPointer?, HelloFn?) -> Int32
    typealias DetachFn = @convention(c) () -> Void
    typealias ReplyFn = @convention(c) (UnsafeMutableRawPointer?, UInt32, UnsafeRawPointer?, Int) -> Void
    typealias SetReplyFn = @convention(c) (UnsafeMutableRawPointer?, ReplyFn?) -> Void
    typealias LastReplyTokenFn = @convention(c) () -> UInt32
    typealias InputAckFn = @convention(c) (UnsafeMutableRawPointer?, Int32, Int32, UInt32) -> Void
    typealias SetInputAckFn = @convention(c) (UnsafeMutableRawPointer?, InputAckFn?) -> Void
    typealias OrderInputFn = @convention(c) (UnsafeMutablePointer<UInt32>?) -> UInt32
    typealias HostWatchFn = @convention(c) (UnsafeMutableRawPointer?, Int32, Int64, Int64) -> Void
    typealias SetHostWatchFn = @convention(c) (UnsafeMutableRawPointer?, HostWatchFn?) -> Void
    typealias EndedFn = @convention(c) (UnsafeMutableRawPointer?, Int32) -> Void
    typealias SetEndedFn = @convention(c) (UnsafeMutableRawPointer?, EndedFn?) -> Void

    /// Resolves the remote dylib's symbols by name (the shim's C ABI, after the host's hello).
    let symbol: (String) -> UnsafeMutableRawPointer?
    private let attachFn: AttachFn
    private let detachFn: DetachFn
    private let setReplyFn: SetReplyFn
    private let setEndedFn: SetEndedFn
    private let lastReplyTokenFn: LastReplyTokenFn
    /// The input ring's two entry points (tasks 042 and 092); nil in a dylib built before them.
    private let setInputAckFn: SetInputAckFn?
    private let orderInputFn: OrderInputFn?
    /// `cmux_remote_shim_set_host_watch`, nil for a remote shim without it.
    private let setHostWatchFn: SetHostWatchFn?

    /// Checks the dylib's ABI identity against `expected`, as ``CEFShimLibrary/open(_:expected:)``
    /// checks the in-process shim, and that it exports the wire entry points and every required
    /// `cmux_shim_*` function: a bad dylib fails here, before it takes the host's descriptors.
    static func make(symbol: @escaping (String) -> UnsafeMutableRawPointer?, expected: String?) throws(CEFShimLibrary.LoadError) -> CEFRemoteShim {
        // SAFETY (this function): `symbol` is dlsym on the remote dylib, whose handle is never closed; each
        // cast is the export's C type in remote_shim_runtime.h and cmux_cef_shim.h, and no export is called
        // before the ABI identity below matches (abiID is the one C type every shim generation shares).
        func resolve<T>(_ name: String) throws(CEFShimLibrary.LoadError) -> T {
            guard let pointer = unsafe symbol(name) else { throw .missingSymbol(name) }
            return unsafe unsafeBitCast(pointer, to: T.self)
        }
        let abiID: @convention(c) () -> UnsafePointer<CChar>? = try unsafe resolve("cmux_shim_abi_id")
        try CEFShimLibrary.checkABI(expected: expected, found: unsafe abiID().map(String.init(cString:)))
        _ = try unsafe CEFShimLibrary.resolving(symbol, hostExports: [])
        // The input ring's two entry points are optional (a dylib built before tasks 042 and 092).
        let setInputAckFn = unsafe symbol("cmux_remote_shim_set_input_ack").map { unsafe unsafeBitCast($0, to: SetInputAckFn.self) }
        let orderInputFn = unsafe symbol("cmux_remote_shim_order_input").map { unsafe unsafeBitCast($0, to: OrderInputFn.self) }
        return try unsafe CEFRemoteShim(symbol: symbol, attachFn: resolve("cmux_remote_shim_attach"),
                                        detachFn: resolve("cmux_remote_shim_detach"), setReplyFn: resolve("cmux_remote_shim_set_reply"),
                                        setEndedFn: resolve("cmux_remote_shim_set_ended"),
                                        lastReplyTokenFn: resolve("cmux_remote_shim_last_reply_token"),
                                        setInputAckFn: setInputAckFn, orderInputFn: orderInputFn,
                                        setHostWatchFn: symbol("cmux_remote_shim_set_host_watch").map { unsafe unsafeBitCast($0, to: SetHostWatchFn.self) })
    }

    /// Opens the remote dylib the attachment names (off the main thread: `dlopen` holds dyld's lock).
    static func open(_ attachment: ChromiumHostAttachment) -> Result<CEFRemoteShim, CEFRuntime.BootError> {
        // SAFETY: dlopen reads the NUL-terminated copy of the path Swift makes for the call.
        guard let handle = unsafe dlopen(attachment.remoteShim.path, RTLD_NOW | RTLD_LOCAL) else {
            // SAFETY: after a failed dlopen, dlerror returns its NUL-terminated message; it is copied at once.
            return .failure(.shim(.open(unsafe String(cString: dlerror()))))
        }
        do {
            // The handle stays open for the life of the process: a shim is never closed.
            // SAFETY: so every symbol dlsym finds on it stays mapped; `make` checks the dylib's ABI identity.
            return .success(try unsafe make(symbol: { unsafe dlsym(handle, $0) }, expected: CEFShimABI.bundledIdentity()))
        } catch {
            return .failure(.shim(error))
        }
    }

    /// Releases the host's wire that ``attach(_:replies:helloDeadline:clock:)`` gave the shim, and
    /// its reply and end sinks.
    func detach() {
        // The host watch hears the detach (input that waited went with the host) before it is cleared.
        detachFn()
        // SAFETY: NULL context and callback clear the reply and end sinks; nothing is read through them.
        unsafe setReplyFn(nil, nil)
        unsafe setEndedFn(nil, nil)
        // SAFETY: NULL context and callback clear the input ack sink the same way.
        unsafe setInputAckFn?(nil, nil)
        // SAFETY: as above, for the host watch.
        if let setHostWatchFn { unsafe setHostWatchFn(nil, nil) }
    }

    /// The remote shim has the input ring's entry points: input acks and ordered input seqs.
    var hasInputRing: Bool { unsafe setInputAckFn != nil && orderInputFn != nil }

    /// Where the host's input acks go from now on (`ack(context, browser, kind, seq)` on the main
    /// thread); nil drops them. Whoever sets a context keeps it alive until it sets another.
    @MainActor
    func setInputAck(context: UnsafeMutableRawPointer?, ack: InputAckFn?) {
        // SAFETY: the shim keeps `context` opaque and passes it back only to `ack`; the caller keeps it alive
        // until it sets another (ChromiumHostInputRoute, released in CEFHostStart.endInputRoute).
        unsafe setInputAckFn?(context, ack)
    }

    /// The next ring frame's input seq and the control seq it follows (task 092); nil with no host
    /// attached (the frame is not written) or a dylib without the entry point.
    @MainActor
    func orderInput() -> (seq: UInt32, ctlSeq: UInt32)? {
        guard let orderInputFn = unsafe orderInputFn else { return nil }
        var ctlSeq: UInt32 = 0
        // SAFETY: the shim writes one UInt32 through the pointer, which is valid for the call.
        let seq = unsafe orderInputFn(&ctlSeq)
        return seq == 0 ? nil : (seq, ctlSeq)
    }

    /// The host watch goes to `monitor` until ``detach()``: false when this remote shim has no host watch.
    @MainActor
    func watchHost(_ monitor: ChromiumHostHangMonitor) -> Bool {
        guard let setHostWatchFn, let token = try? monitor.token() else { return false }
        // SAFETY: the context is the monitor's registry token, never its address: a frame after the monitor is
        // gone finds nothing (ChromiumHostHangMonitorRegistration); the callback is a C function of
        // `cmux_remote_host_watch_fn`.
        unsafe setHostWatchFn(token.context, ChromiumHostHangMonitor.hostWatchCallback)
        return true
    }

    /// The REPLY token of the async shim call this turn just made (0: it sent nothing).
    @MainActor
    func lastReplyToken() -> UInt32 {
        lastReplyTokenFn()
    }

    /// Hands the host's wire to the remote shim and returns, once the host's hello is in, the
    /// optional exports its shim defines. Fails when the shim refused the wire (its descriptors
    /// are closed here), the host ended first (the shim closed them), or no hello came within
    /// `helloDeadline` on `clock` (the shim is detached), as Chrome gives up on a GPU channel the
    /// GPU process never establishes (content/browser/gpu/browser_gpu_channel_host_factory.cc).
    /// The host's REPLY frames go to `replies` from here until ``detach()``, and so does the wire's
    /// own end (``CEFHostReplies/wireEnded()``); one that comes after `replies` is gone finds nothing
    /// (``CEFReplySinkRegistration``).
    @MainActor
    func attach(_ attachment: ChromiumHostAttachment, replies: CEFHostReplies, helloDeadline: Duration,
                clock: any Clock<Duration>) async -> Result<Set<String>, CEFRuntime.BootError> {
        let sink: CallbackToken
        do throws(CallbackRegistryError) {
            sink = try replies.replySinkToken()
        } catch {
            attachment.closeDescriptors()
            return .failure(.host("no reply slot for the host's wire: \(error)"))
        }
        let hello = CEFRemoteHello()
        // SAFETY: the +1 retain is the hello's context: CEFRemoteHello.callback takes it back once (the shim runs
        // hello exactly once per accepted attach), or the release below does when the shim refuses the wire.
        let context = unsafe Unmanaged.passRetained(hello).toOpaque()
        // SAFETY: the sink's context is the table's token, never its address: a REPLY after the table is gone
        // finds nothing (CEFRemoteReplySink).
        unsafe setReplyFn(sink.context, CEFRemoteReplySink.callback)
        // SAFETY: as the reply sink: the context is the table's token.
        unsafe setEndedFn(sink.context, CEFRemoteReplySink.ended)
        // SAFETY: the context is the +1 hello above; the callback is a C function of `cmux_remote_shim_hello_fn`.
        guard unsafe attachFn(attachment.controlFD, attachment.inputRingFD, attachment.outputRingFD, context, CEFRemoteHello.callback) == 1 else {
            // SAFETY: as in detach().
            unsafe setReplyFn(nil, nil)
            unsafe setEndedFn(nil, nil)
            // SAFETY: a refused attach calls nothing, so no hello takes the context; this drops the +1 once.
            unsafe Unmanaged<CEFRemoteHello>.fromOpaque(context).release()
            attachment.closeDescriptors()
            return .failure(.host("the remote shim refused the host's wire"))
        }
        let deadline = Task { [self] in
            // wakeup-allow: deadline of the host's hello, raced against the hello in attach(), which awaits the outcome
            // and cancels it; not a DemandTimer; injected clock
            do { try await clock.sleep(for: helloDeadline, tolerance: WakeLeeway.window(delay: helloDeadline).tolerance) } catch { return }
            // Detach runs the pending hello with 0, which releases its context; none comes after.
            if hello.finish(.timedOut) { detach() }
        }
        let outcome = await hello.outcome()
        deadline.cancel()
        return switch outcome {
        case .attached(let exports): .success(exports)
        case .ended: .failure(.host("the host ended before its hello"))
        case .timedOut: .failure(.host("no hello from the host within \(helloDeadline)"))
        }
    }
}

/// One attach's hello: the first outcome wins (the host's hello, its end, or the deadline);
/// ``CEFRemoteShim/attach(_:replies:helloDeadline:clock:)`` awaits it.
private final class CEFRemoteHello {
    nonisolated enum Outcome: Equatable, Sendable {
        case attached(Set<String>)
        case ended
        case timedOut
    }

    private var result: Outcome?
    private var waiter: OnceContinuation<Outcome, OnceContinuationError>?

    /// Records `outcome` unless one is already in; false when one was (a hello after the deadline).
    @discardableResult
    func finish(_ outcome: Outcome) -> Bool {
        guard result == nil else { return false }
        result = outcome
        waiter?.resume(returning: outcome)
        waiter = nil
        return true
    }

    func outcome() async -> Outcome {
        if let result { return result }
        // A waiter dropped unresumed (abandoned) ends the attach.
        let outcome = try? await withOnceContinuation { (continuation: OnceContinuation<Outcome, OnceContinuationError>) in
            waiter = continuation
        }
        return outcome ?? .ended
    }

    /// C entry for the host's hello: runs once per accepted attach, on the main thread, and
    /// releases the context the attach retained.
    static let callback: CEFRemoteShim.HelloFn = { context, attached, exports in
        // SAFETY: a non-NULL context is the +1 hello `attach` gave, passed back once; this takes the +1 back.
        guard let hello = unsafe context.map({ unsafe Unmanaged<CEFRemoteHello>.fromOpaque($0).takeRetainedValue() }) else { return }
        // SAFETY: the exports list is NUL-terminated and valid during this call; String(cString:) copies it.
        let names = unsafe exports.map(String.init(cString:)) ?? ""
        let outcome: Outcome = attached == 1 ? .attached(Set(names.split(separator: "\n").map(String.init))) : .ended
        MainActor.assumeIsolated { // main-proof: cmux_remote_shim_attach's contract runs hello on the main thread
            _ = hello.finish(outcome)
        }
    }
}

/// The host's REPLY frames into a ``CEFHostReplies`` (``CEFRemoteShim/attach(_:replies:helloDeadline:clock:)``).
private struct CEFRemoteReplySink {
    /// C entry: runs on the main thread (remote_shim_runtime.h `cmux_remote_reply_fn`) with the
    /// table's token as its context, and only copies the fields, which are valid during the call alone.
    static let callback: CEFRemoteShim.ReplyFn = { context, token, fields, length in
        // The raw context is not Sendable; the main-actor table it names is, so the closure
        // captures the table (as the hello's callback captures its waiter).
        // A token whose table is gone finds nothing (the registry counts it).
        guard let replies = unsafe CEFReplySinkRegistration.tables.target(forContext: context) else { return }
        // SAFETY: `fields` holds `length` bytes during this call alone; Array copies them.
        let body = unsafe fields.map { unsafe Array(UnsafeRawBufferPointer(start: $0, count: max(length, 0))) } ?? []
        MainActor.assumeIsolated { // main-proof: cmux_remote_reply_fn runs on the main thread (remote_shim_runtime.h)
            _ = replies.resolve(token, fields: body)
        }
    }

    /// C entry for the wire's end: runs on the main thread (remote_shim_runtime.h `cmux_remote_ended_fn`)
    /// with the table's token as its context, after the shim dropped the tokens it awaited.
    static let ended: CEFRemoteShim.EndedFn = { context, _ in
        guard let replies = unsafe CEFReplySinkRegistration.tables.target(forContext: context) else { return }
        MainActor.assumeIsolated { // main-proof: cmux_remote_ended_fn runs on the main thread (remote_shim_runtime.h)
            replies.wireEnded()
        }
    }
}
