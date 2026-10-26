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
/// - `void cmux_remote_shim_detach(void)`: the host is gone; a later attach serves the next host.
///
/// Immutable C function pointers and the `dlopen` handle: safe to hand from the loading thread to main.
// crash-allow: every stored property is a let: C function pointers and a dlsym closure over a handle never closed; nothing mutates after make.
nonisolated struct CEFRemoteShim: @unchecked Sendable {
    typealias HelloFn = @convention(c) (UnsafeMutableRawPointer?, Int32, UnsafePointer<CChar>?) -> Void
    typealias AttachFn = @convention(c) (Int32, Int32, Int32, UnsafeMutableRawPointer?, HelloFn?) -> Int32

    /// Resolves the remote dylib's symbols by name.
    let symbol: (String) -> UnsafeMutableRawPointer?
    let attachFn: AttachFn
    /// For the supervisor's host restart (task 080).
    let detach: @convention(c) () -> Void

    /// Resolves the wire entry points and checks the dylib's ABI identity against `expected`, as
    /// ``CEFShimLibrary/open(_:expected:)`` checks the in-process shim.
    static func make(symbol: @escaping (String) -> UnsafeMutableRawPointer?, expected: String?) throws(CEFShimLibrary.LoadError) -> CEFRemoteShim {
        func resolve<T>(_ name: String) throws(CEFShimLibrary.LoadError) -> T {
            guard let pointer = symbol(name) else { throw .missingSymbol(name) }
            return unsafeBitCast(pointer, to: T.self)
        }
        let abiID: @convention(c) () -> UnsafePointer<CChar>? = try resolve("cmux_shim_abi_id")
        try CEFShimLibrary.checkABI(expected: expected, found: abiID().map { String(cString: $0) })
        return CEFRemoteShim(symbol: symbol, attachFn: try resolve("cmux_remote_shim_attach"),
                             detach: try resolve("cmux_remote_shim_detach"))
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

    /// Hands the host's wire to the remote shim and returns, once the host's hello is in, the
    /// optional exports its shim defines; nil when the shim refused the wire (its descriptors are
    /// closed here) or the host ended first (the shim owns and closes them).
    @MainActor
    func attach(_ attachment: ChromiumHostAttachment) async -> Set<String>? {
        await withCheckedContinuation { (continuation: CheckedContinuation<Set<String>?, Never>) in
            let context = Unmanaged.passRetained(CEFRemoteHello(continuation)).toOpaque()
            guard attachFn(attachment.controlFD, attachment.inputRingFD, attachment.outputRingFD, context, cefRemoteHelloCallback) == 1 else {
                Unmanaged<CEFRemoteHello>.fromOpaque(context).release()
                attachment.closeDescriptors()
                continuation.resume(returning: nil)
                return
            }
        }
    }
}

/// The continuation ``CEFRemoteShim/attach(_:)`` resumes from the hello callback.
private nonisolated final class CEFRemoteHello: Sendable {
    let continuation: CheckedContinuation<Set<String>?, Never>

    init(_ continuation: CheckedContinuation<Set<String>?, Never>) {
        self.continuation = continuation
    }
}

/// C entry for the host's hello: runs once per accepted attach and resumes its awaiter.
private let cefRemoteHelloCallback: CEFRemoteShim.HelloFn = { context, attached, exports in
    guard let context else { return }
    let hello = Unmanaged<CEFRemoteHello>.fromOpaque(context).takeRetainedValue()
    guard attached == 1 else { return hello.continuation.resume(returning: nil) }
    let names = exports.map { String(cString: $0) } ?? ""
    hello.continuation.resume(returning: Set(names.split(separator: "\n").map(String.init)))
}
