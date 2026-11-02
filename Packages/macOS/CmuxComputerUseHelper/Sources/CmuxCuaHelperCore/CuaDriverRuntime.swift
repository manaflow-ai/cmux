// SPDX-License-Identifier: GPL-3.0-or-later
import CCuaDriverABI
import Darwin
import Foundation
import os

/// Upstream Cua Driver, in process, through its stable C ABI (cua_driver_*_v1).
/// The library is the pinned libcua_driver_sdk.dylib in the helper's
/// Frameworks directory; it is opened with dlopen so the package builds
/// without it. There is no upstream daemon and no upstream socket.
///
/// The driver is created with the immutable `authorization` ceiling of the
/// configured mode (`ComputerUseConfiguration.driverOptions`), and every
/// call runs in a trusted session (`cua_driver_session_create_v1`) that the
/// worker binds to one admitted connection (`ComputerUseSessions`).
// crash-allow: the handle and function pointers are immutable after init, and the C ABI is thread safe for these calls.
public final class CuaDriverRuntime: CuaDriverSessionFactory, @unchecked Sendable {
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
    typealias SessionCreateFn = @convention(c) (OpaquePointer?, UnsafePointer<UInt8>?, Int, UnsafeMutablePointer<OpaquePointer?>?, UnsafeMutablePointer<CuaDriverBuffer>?) -> Int32
    typealias SessionDestroyFn = @convention(c) (UnsafeMutablePointer<OpaquePointer?>?) -> Void

    public enum LoadError: Error, CustomStringConvertible {
        case open(String)
        case symbol(String)
        case incompatible(major: UInt16, minor: UInt16)
        case create(String)
        case manifest(String)

        public var description: String {
            switch self {
            case .open(let message): "cannot open the Cua Driver library: \(message)"
            case .symbol(let name): "the Cua Driver library lacks \(name)"
            case .incompatible(let major, let minor): "the Cua Driver library ABI \(major).\(minor) is not compatible"
            case .create(let message): "cua_driver_create_v1 failed: \(message)"
            case .manifest(let message): "cannot write the Computer Use manifest: \(message)"
            }
        }
    }

    private let library: UnsafeMutableRawPointer
    private let handle: OpaquePointer
    private let free: FreeFn
    private let list: ListFn
    private let release: ReleaseFn
    private let sessionCreate: SessionCreateFn
    private let sessionInvoke: InvokeFn
    private let sessionDestroy: SessionDestroyFn

    /// Loads the library and creates the driver under `configuration`'s
    /// ceiling. Under `ask` the compatibility context needs a manifest; it
    /// gets one that lists no app (the worker never calls outside a session).
    public init(libraryPath: String, configuration: ComputerUseConfiguration, manifests: ManifestStoreLocation) throws {
        guard let library = dlopen(libraryPath, RTLD_NOW | RTLD_LOCAL) else {
            throw LoadError.open(String(cString: dlerror()))
        }
        func symbol<T>(_ name: String, _: T.Type) throws -> T {
            guard let pointer = dlsym(library, name) else { throw LoadError.symbol(name) }
            return unsafeBitCast(pointer, to: T.self)
        }
        let version = try symbol("cua_driver_abi_version_v1", VersionFn.self)
        let compatible = try symbol("cua_driver_abi_is_compatible_v1", CompatibleFn.self)
        let create = try symbol("cua_driver_create_v1", CreateFn.self)
        free = try symbol("cua_driver_buffer_free_v1", FreeFn.self)
        list = try symbol("cua_driver_list_tools_json_v1", ListFn.self)
        release = try symbol("cua_driver_operation_release_v1", ReleaseFn.self)
        sessionCreate = try symbol("cua_driver_session_create_v1", SessionCreateFn.self)
        sessionInvoke = try symbol("cua_driver_session_invoke_v1", InvokeFn.self)
        sessionDestroy = try symbol("cua_driver_session_destroy_v1", SessionDestroyFn.self)
        var runtimeVersion = CuaDriverAbiVersion()
        runtimeVersion.struct_size = UInt32(MemoryLayout<CuaDriverAbiVersion>.size)
        guard version(&runtimeVersion) == 0,
              compatible(UInt16(CUA_DRIVER_ABI_MAJOR), UInt16(CUA_DRIVER_ABI_MINOR)) else {
            throw LoadError.incompatible(major: runtimeVersion.major, minor: runtimeVersion.minor)
        }
        var compatibilityManifest: String?
        var temporaryManifest: String?
        let store = ManifestStore(directory: manifests.directory)
        switch configuration.mode {
        case .ask:
            do {
                let path = try store.write(CapabilityManifest.compatibility.data, name: "compatibility.json")
                compatibilityManifest = path
                temporaryManifest = path
            } catch {
                throw LoadError.manifest(String(describing: error))
            }
        case .bounded:
            compatibilityManifest = configuration.ownerManifestPath
        case .standard, .unrestricted:
            break
        }
        defer { if let temporaryManifest { store.remove(temporaryManifest) } }
        let options = [UInt8](configuration.driverOptions(compatibilityManifestPath: compatibilityManifest))
        var created: OpaquePointer?
        var error = CuaDriverBuffer()
        guard create(options, options.count, &created, &error) == 0, let created else {
            throw LoadError.create(Self.take(&error, free))
        }
        self.library = library
        self.handle = created
    }

    public func inventory() throws -> Data {
        var json = CuaDriverBuffer()
        var error = CuaDriverBuffer()
        guard list(handle, &json, &error) == 0 else { throw ToolError(Self.take(&error, free)) }
        _ = Self.take(&error, free)
        return Data(Self.take(&json, free).utf8)
    }

    public func createSession(options: Data) throws -> any CuaDriverSessionInvoking {
        let bytes = [UInt8](options)
        var session: OpaquePointer?
        var error = CuaDriverBuffer()
        guard sessionCreate(handle, bytes, bytes.count, &session, &error) == 0, let session else {
            throw ToolError("cua_driver_session_create_v1 failed: \(Self.take(&error, free))")
        }
        return CuaDriverSession(handle: session, invokeFn: sessionInvoke, destroyFn: sessionDestroy,
                                free: free, release: release)
    }

    static func take(_ buffer: inout CuaDriverBuffer, _ free: FreeFn) -> String {
        defer { free(&buffer) }
        guard let data = buffer.data, buffer.len > 0 else { return "" }
        return String(decoding: UnsafeBufferPointer(start: data, count: buffer.len), as: UTF8.self)
    }

    // crash-allow: the continuation is resumed exactly once, by the driver's completion, which owns the box.
    final class CompletionBox: @unchecked Sendable {
        let continuation: CheckedContinuation<Data, any Error>
        let free: FreeFn

        init(continuation: CheckedContinuation<Data, any Error>, free: FreeFn) {
            self.continuation = continuation
            self.free = free
        }

        func complete(status: Int32, result: CuaDriverBuffer, error: CuaDriverBuffer) {
            var result = result
            var error = error
            let resultText = CuaDriverRuntime.take(&result, free)
            let errorText = CuaDriverRuntime.take(&error, free)
            if status == 0 {
                continuation.resume(returning: Data(resultText.utf8))
            } else {
                continuation.resume(throwing: ToolError(errorText.isEmpty ? "status \(status)" : errorText))
            }
        }
    }
}

/// Where the runtime and the sessions write manifests.
public struct ManifestStoreLocation: Sendable {
    public let directory: String

    public init(directory: String) { self.directory = directory }

    /// A per-process directory under this user's temp directory, or nil.
    public static func perProcess() -> ManifestStoreLocation? {
        ManifestStore.defaultDirectory().map(ManifestStoreLocation.init(directory:))
    }
}

/// One trusted upstream session: its authority lives in the handle, never
/// in a request. `destroy` revokes its connection-bound grants; a call
/// after it fails.
// crash-allow: the session pointer is read and cleared only under `state`'s lock; the function pointers are immutable.
final class CuaDriverSession: CuaDriverSessionInvoking, @unchecked Sendable {
    private let state: OSAllocatedUnfairLock<OpaquePointer?>
    private let invokeFn: CuaDriverRuntime.InvokeFn
    private let destroyFn: CuaDriverRuntime.SessionDestroyFn
    private let free: CuaDriverRuntime.FreeFn
    private let release: CuaDriverRuntime.ReleaseFn

    init(handle: OpaquePointer, invokeFn: CuaDriverRuntime.InvokeFn, destroyFn: CuaDriverRuntime.SessionDestroyFn,
         free: CuaDriverRuntime.FreeFn, release: CuaDriverRuntime.ReleaseFn) {
        state = OSAllocatedUnfairLock(uncheckedState: handle)
        self.invokeFn = invokeFn
        self.destroyFn = destroyFn
        self.free = free
        self.release = release
    }

    deinit { destroy() }

    func invoke(name: String, arguments: Data) async throws -> Data {
        let free = self.free
        let release = self.release
        let invokeFn = self.invokeFn
        return try await withCheckedThrowingContinuation { continuation in
            let box = Unmanaged.passRetained(CuaDriverRuntime.CompletionBox(continuation: continuation, free: free))
            var operation: OpaquePointer?
            var error = CuaDriverBuffer()
            let nameBytes = Array(name.utf8)
            let argumentBytes = [UInt8](arguments)
            // The lock is held only to start the call, so destroy cannot free the handle under it.
            let status: Int32 = state.withLockUnchecked { handle in
                guard let handle else { return -1 }
                return invokeFn(handle, nameBytes, nameBytes.count, argumentBytes, argumentBytes.count,
                                { context, status, result, error in
                                    guard let context else { return }
                                    let box = Unmanaged<CuaDriverRuntime.CompletionBox>.fromOpaque(context)
                                        .takeRetainedValue()
                                    box.complete(status: status, result: result, error: error)
                                },
                                box.toOpaque(), &operation, &error)
            }
            if status != 0 {
                box.release()
                let message = status == -1 ? "the Computer Use session ended" : CuaDriverRuntime.take(&error, free)
                continuation.resume(throwing: ToolError(message))
            } else {
                // The completion owns the result; the token is released now
                // (cancellation is not used).
                release(&operation)
            }
        }
    }

    func destroy() {
        var handle = state.withLockUnchecked { value -> OpaquePointer? in
            let old = value
            value = nil
            return old
        }
        if handle != nil { destroyFn(&handle) }
    }
}

/// Stands in when the library did not load: every call fails with the reason.
public struct UnavailableTools: ToolInvoking {
    public let reason: String
    public init(reason: String) { self.reason = reason }
    public func listTools() async throws -> Data { throw ToolError(reason) }
    public func invoke(name: String, arguments: Data) async throws -> Data { throw ToolError(reason) }
}
