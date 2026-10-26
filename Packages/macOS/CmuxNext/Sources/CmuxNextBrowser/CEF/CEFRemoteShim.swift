import Darwin
import Foundation

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
///
/// Immutable C function pointers and a `dlsym` lookup over a handle that is never closed.
// crash-allow: every stored property is a let (C function pointers, a dlsym closure over a dlopen handle never closed; dlsym is thread-safe); nothing mutates after make, as in CEFShimLibrary.
nonisolated struct CEFRemoteShim: @unchecked Sendable {
    typealias HelloFn = @convention(c) (UnsafeMutableRawPointer?, Int32, UnsafePointer<CChar>?) -> Void
    typealias AttachFn = @convention(c) (Int32, Int32, Int32, UnsafeMutableRawPointer?, HelloFn?) -> Int32
    typealias DetachFn = @convention(c) () -> Void

    /// Resolves the remote dylib's symbols by name (the shim's C ABI, after the host's hello).
    let symbol: (String) -> UnsafeMutableRawPointer?
    private let attachFn: AttachFn
    private let detachFn: DetachFn

    /// Checks the dylib's ABI identity against `expected`, as ``CEFShimLibrary/open(_:expected:)``
    /// checks the in-process shim, and that it exports the wire entry points and every required
    /// `cmux_shim_*` function: a bad dylib fails here, before it takes the host's descriptors.
    static func make(symbol: @escaping (String) -> UnsafeMutableRawPointer?, expected: String?) throws(CEFShimLibrary.LoadError) -> CEFRemoteShim {
        func resolve<T>(_ name: String) throws(CEFShimLibrary.LoadError) -> T {
            guard let pointer = symbol(name) else { throw .missingSymbol(name) }
            return unsafeBitCast(pointer, to: T.self)
        }
        let abiID: @convention(c) () -> UnsafePointer<CChar>? = try resolve("cmux_shim_abi_id")
        try CEFShimLibrary.checkABI(expected: expected, found: abiID().map { String(cString: $0) })
        _ = try CEFShimLibrary.resolving(symbol, hostExports: [])
        return CEFRemoteShim(symbol: symbol, attachFn: try resolve("cmux_remote_shim_attach"),
                             detachFn: try resolve("cmux_remote_shim_detach"))
    }

    /// Opens the remote dylib the attachment names (off the main thread: `dlopen` holds dyld's lock).
    static func open(_ attachment: ChromiumHostAttachment) -> Result<CEFRemoteShim, CEFRuntime.BootError> {
        guard let handle = dlopen(attachment.remoteShim.path, RTLD_NOW | RTLD_LOCAL) else {
            return .failure(.shim(.open(String(cString: dlerror()))))
        }
        do {
            // The handle stays open for the life of the process: a shim is never closed.
            return .success(try make(symbol: { dlsym(handle, $0) }, expected: CEFShimABI.bundledIdentity()))
        } catch {
            return .failure(.shim(error))
        }
    }

    /// Releases the host's wire that ``attach(_:helloDeadline:clock:)`` gave the shim.
    func detach() {
        detachFn()
    }

    /// Hands the host's wire to the remote shim and returns, once the host's hello is in, the
    /// optional exports its shim defines. Fails when the shim refused the wire (its descriptors
    /// are closed here), the host ended first (the shim closed them), or no hello came within
    /// `helloDeadline` on `clock` (the shim is detached), as Chrome gives up on a GPU channel the
    /// GPU process never establishes (content/browser/gpu/browser_gpu_channel_host_factory.cc).
    @MainActor
    func attach(_ attachment: ChromiumHostAttachment, helloDeadline: Duration,
                clock: any Clock<Duration>) async -> Result<Set<String>, CEFRuntime.BootError> {
        let hello = CEFRemoteHello()
        let context = Unmanaged.passRetained(hello).toOpaque()
        guard attachFn(attachment.controlFD, attachment.inputRingFD, attachment.outputRingFD, context, CEFRemoteHello.callback) == 1 else {
            Unmanaged<CEFRemoteHello>.fromOpaque(context).release()
            attachment.closeDescriptors()
            return .failure(.host("the remote shim refused the host's wire"))
        }
        let deadline = Task { [self] in
            // wakeup-allow: one-shot hello deadline on the injected clock, cancelled when the hello arrives
            do { try await clock.sleep(for: helloDeadline) } catch { return }
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
/// ``CEFRemoteShim/attach(_:helloDeadline:clock:)`` awaits it.
private final class CEFRemoteHello {
    nonisolated enum Outcome: Equatable, Sendable {
        case attached(Set<String>)
        case ended
        case timedOut
    }

    private var result: Outcome?
    private var waiter: CheckedContinuation<Outcome, Never>?

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
        return await withCheckedContinuation { waiter = $0 }
    }

    /// C entry for the host's hello: runs once per accepted attach, on the main thread, and
    /// releases the context the attach retained.
    static let callback: CEFRemoteShim.HelloFn = { context, attached, exports in
        guard let context else { return }
        let hello = Unmanaged<CEFRemoteHello>.fromOpaque(context).takeRetainedValue()
        let names = exports.map { String(cString: $0) } ?? ""
        let outcome: Outcome = attached == 1 ? .attached(Set(names.split(separator: "\n").map(String.init))) : .ended
        MainActor.assumeIsolated { // main-proof: cmux_remote_shim_attach's contract runs hello on the main thread
            _ = hello.finish(outcome)
        }
    }
}
