// SPDX-License-Identifier: GPL-3.0-or-later
import CCuaDriverABI
import Darwin
import Foundation
import class CmuxSafeConcurrency.OnceContinuation
import func CmuxSafeConcurrency.withOnceThrowingContinuation

/// Upstream Cua Driver, in process, through its stable C ABI (cua_driver_*_v1).
/// The library is the pinned libcua_driver_sdk.dylib in the helper's
/// Frameworks directory; it is opened with dlopen so the package builds
/// without it. There is no upstream daemon and no upstream socket.
/// An actor: the C ABI does not promise that one driver handle takes calls
/// from several threads at once, so list and invoke submissions run one at a
/// time. The actor is reentrant, so a pending invoke never blocks the next.
/// `@safe`: the library handle, the driver handle and the C function pointers
/// never leave the actor, and each call into the ABI states its contract.
@safe public actor CuaDriverRuntime: ToolInvoking {
    typealias VersionFn = @convention(c) (UnsafeMutablePointer<CuaDriverAbiVersion>?) -> Int32
    typealias CompatibleFn = @convention(c) (UInt16, UInt16) -> Bool
    typealias FreeFn = @convention(c) (UnsafeMutablePointer<CuaDriverBuffer>?) -> Void
    typealias CreateFn = @convention(c) (UnsafePointer<UInt8>?, Int, UnsafeMutablePointer<OpaquePointer?>?, UnsafeMutablePointer<CuaDriverBuffer>?) -> Int32
    typealias ListFn = @convention(c) (OpaquePointer?, UnsafeMutablePointer<CuaDriverBuffer>?, UnsafeMutablePointer<CuaDriverBuffer>?) -> Int32
    /// CuaDriverCompletionV1 with the status as its int32_t (the header's
    /// enum and typedef of the same name are ambiguous in Swift).
    typealias CompletionFn = @convention(c) (UnsafeMutableRawPointer?, Int32, CuaDriverBuffer, CuaDriverBuffer) -> Void
    typealias InvokeFn = @convention(c) (OpaquePointer?, UnsafePointer<UInt8>?, Int, UnsafePointer<UInt8>?, Int, CompletionFn?, UnsafeMutableRawPointer?, UnsafeMutablePointer<OpaquePointer?>?, UnsafeMutablePointer<CuaDriverBuffer>?) -> Int32
    typealias ReleaseFn = @convention(c) (UnsafeMutablePointer<OpaquePointer?>?) -> Void

    public enum LoadError: Error, CustomStringConvertible {
        case open(String)
        case symbol(String)
        case incompatible(major: UInt16, minor: UInt16)
        case create(String)

        public var description: String {
            switch self {
            case .open(let message): "cannot open the Cua Driver library: \(message)"
            case .symbol(let name): "the Cua Driver library lacks \(name)"
            case .incompatible(let major, let minor): "the Cua Driver library ABI \(major).\(minor) is not compatible"
            case .create(let message): "cua_driver_create_v1 failed: \(message)"
            }
        }
    }

    private let library: UnsafeMutableRawPointer
    private let handle: OpaquePointer
    private let free: FreeFn
    private let list: ListFn
    private let invokeFn: InvokeFn
    private let release: ReleaseFn

    public init(libraryPath: String) throws {
        // SAFETY: dlopen reads the NUL-terminated copy of `libraryPath` Swift makes for the
        // call. dlerror's text is copied into a String at once, before any other dl call
        // on this thread can replace it; a nil message (none pending) reads nothing.
        guard let library = unsafe dlopen(libraryPath, RTLD_NOW | RTLD_LOCAL) else {
            throw LoadError.open(unsafe dlerror().map { unsafe String(cString: $0) } ?? "dlopen failed")
        }
        func symbol<T>(_ name: String, _: T.Type) throws -> T {
            // SAFETY: each caller below names a cua_driver_*_v1 symbol with the
            // @convention(c) type that matches its declaration in the vendored
            // cua_driver_abi.h, whose ABI version is checked right after loading, so the
            // bit cast only gives the symbol address its declared function type.
            guard let pointer = unsafe dlsym(library, name) else { throw LoadError.symbol(name) }
            return unsafe unsafeBitCast(pointer, to: T.self)
        }
        // SAFETY: see symbol(_:_:): each name is paired with its header's function type.
        let version = try unsafe symbol("cua_driver_abi_version_v1", VersionFn.self)
        let compatible = try symbol("cua_driver_abi_is_compatible_v1", CompatibleFn.self)
        let create = try unsafe symbol("cua_driver_create_v1", CreateFn.self)
        let free = try unsafe symbol("cua_driver_buffer_free_v1", FreeFn.self)
        let list = try unsafe symbol("cua_driver_list_tools_json_v1", ListFn.self)
        let invokeFn = try unsafe symbol("cua_driver_invoke_v1", InvokeFn.self)
        let release = try unsafe symbol("cua_driver_operation_release_v1", ReleaseFn.self)
        var runtimeVersion = CuaDriverAbiVersion()
        runtimeVersion.struct_size = UInt32(MemoryLayout<CuaDriverAbiVersion>.size)
        // SAFETY: the version call writes at most runtimeVersion.struct_size bytes (the
        // size of the struct, set above) into `runtimeVersion`, a local of that type.
        guard unsafe version(&runtimeVersion) == 0,
              compatible(UInt16(CUA_DRIVER_ABI_MAJOR), UInt16(CUA_DRIVER_ABI_MINOR)) else {
            throw LoadError.incompatible(major: runtimeVersion.major, minor: runtimeVersion.minor)
        }
        // Empty options: the embedded runtime, standard permission mode; the
        // host (this helper) owns the permission UX, so check_permissions
        // reports attribution "host".
        var created: OpaquePointer?
        var error = CuaDriverBuffer()
        // SAFETY: empty options (nil, 0) read nothing; create writes one handle into
        // `created` and on failure one caller-owned buffer into `error`, both locals.
        guard unsafe create(nil, 0, &created, &error) == 0, let created = unsafe created else {
            throw LoadError.create(unsafe Self.take(&error, free))
        }
        // SAFETY: the actor keeps the library loaded (never dlclose'd) and the handle for
        // its whole life; neither leaves it.
        unsafe self.library = library
        unsafe self.handle = created
        unsafe self.free = free
        unsafe self.list = list
        unsafe self.invokeFn = invokeFn
        unsafe self.release = release
    }

    public func listTools() async throws -> Data {
        var json = CuaDriverBuffer()
        var error = CuaDriverBuffer()
        // SAFETY: `handle` is live for the actor's life; the call writes one caller-owned
        // buffer into each local, and take frees both.
        guard unsafe list(handle, &json, &error) == 0 else { throw ToolError(unsafe Self.take(&error, free)) }
        _ = unsafe Self.take(&error, free)
        return Data(unsafe Self.take(&json, free).utf8)
    }

    public func invoke(name: String, arguments: Data) async throws -> Data {
        let free = unsafe self.free
        let release = unsafe self.release
        return try await withOnceThrowingContinuation { (continuation: OnceContinuation<Data, any Error>) in
            // SAFETY: the box is retained once here and released exactly once: by the
            // completion's takeRetainedValue when invoke returns 0 (the ABI then calls the
            // completion exactly once, cua_driver_abi.h), or by box.release() below when
            // it fails (the ABI then never calls it).
            let box = unsafe Unmanaged.passRetained(CompletionBox(continuation: continuation, free: free))
            var operation: OpaquePointer?
            var error = CuaDriverBuffer()
            let nameBytes = Array(name.utf8)
            let argumentBytes = [UInt8](arguments)
            // SAFETY: the driver reads nameBytes.count and argumentBytes.count bytes, the
            // counts passed, from the two arrays during the call (it copies what it keeps);
            // it writes one operation token into `operation` and on failure one buffer into
            // `error`, both locals. `handle` is live for the actor's life.
            let status = unsafe invokeFn(handle, nameBytes, nameBytes.count, argumentBytes, argumentBytes.count,
                                         { context, status, result, error in
                                             // SAFETY: `context` is the box.toOpaque() passed with this
                                             // completion, returned unchanged; this balances passRetained.
                                             let box = unsafe Unmanaged<CompletionBox>.fromOpaque(context!).takeRetainedValue()
                                             box.complete(status: status, result: result, error: error)
                                         },
                                         box.toOpaque(), &operation, &error)
            if status != 0 {
                // SAFETY: invoke failed, so the ABI never calls the completion: this is the
                // one release that balances passRetained above.
                unsafe box.release()
                continuation.resume(throwing: ToolError(unsafe Self.take(&error, free)))
            } else {
                // The completion owns the result; the token is released now
                // (cancellation is not used in phase 1).
                // SAFETY: `operation` holds the token invoke wrote; release clears it.
                unsafe release(&operation)
            }
        }
    }

    /// The UTF-8 text of a caller-owned ABI buffer, which it then frees.
    static func take(_ buffer: inout CuaDriverBuffer, _ free: FreeFn) -> String {
        // SAFETY: `buffer` was filled by this ABI and is freed once, after the copy below;
        // free clears it, so a second free is harmless (cua_driver_buffer_free_v1).
        defer { unsafe free(&buffer) }
        guard let data = unsafe buffer.data, buffer.len > 0 else { return "" }
        // SAFETY: the ABI's buffer holds `len` initialized bytes at `data` until the free
        // above; String(decoding:) copies them first.
        return unsafe String(decoding: UnsafeBufferPointer(start: data, count: buffer.len), as: UTF8.self)
    }

    // crash-allow: two immutable lets, a CheckedContinuation (Sendable) and a C function pointer (a code address with no state); the ABI calls the completion exactly once.
    // `@safe`: `free` is the ABI's own buffer-free function, called only through take.
    @safe final class CompletionBox: @unchecked Sendable {
        let continuation: OnceContinuation<Data, any Error>
        let free: FreeFn

        init(continuation: OnceContinuation<Data, any Error>, free: FreeFn) {
            self.continuation = continuation
            // SAFETY: stores the function pointer the runtime resolved; see the type note.
            unsafe self.free = free
        }

        func complete(status: Int32, result: CuaDriverBuffer, error: CuaDriverBuffer) {
            var result = result
            var error = error
            // SAFETY: both buffers come from this completion call, caller-owned by the ABI's
            // contract, and each is freed once by take.
            let resultText = unsafe CuaDriverRuntime.take(&result, free)
            let errorText = unsafe CuaDriverRuntime.take(&error, free)
            if status == 0 {
                continuation.resume(returning: Data(resultText.utf8))
            } else {
                continuation.resume(throwing: ToolError(errorText.isEmpty ? "status \(status)" : errorText))
            }
        }
    }
}

/// Stands in when the library did not load: every call fails with the reason.
public struct UnavailableTools: ToolInvoking {
    public let reason: String
    public init(reason: String) { self.reason = reason }
    public func listTools() async throws -> Data { throw ToolError(reason) }
    public func invoke(name: String, arguments: Data) async throws -> Data { throw ToolError(reason) }
}
