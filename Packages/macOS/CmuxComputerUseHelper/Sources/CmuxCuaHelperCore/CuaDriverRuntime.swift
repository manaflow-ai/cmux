// SPDX-License-Identifier: GPL-3.0-or-later
import CCuaDriverABI
import Darwin
import Foundation

/// Upstream Cua Driver, in process, through its stable C ABI (cua_driver_*_v1).
/// The library is the pinned libcua_driver_sdk.dylib in the helper's
/// Frameworks directory; it is opened with dlopen so the package builds
/// without it. There is no upstream daemon and no upstream socket.
public final class CuaDriverRuntime: ToolInvoking, @unchecked Sendable {
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
        invokeFn = try symbol("cua_driver_invoke_v1", InvokeFn.self)
        release = try symbol("cua_driver_operation_release_v1", ReleaseFn.self)
        var runtimeVersion = CuaDriverAbiVersion()
        runtimeVersion.struct_size = UInt32(MemoryLayout<CuaDriverAbiVersion>.size)
        guard version(&runtimeVersion) == 0,
              compatible(UInt16(CUA_DRIVER_ABI_MAJOR), UInt16(CUA_DRIVER_ABI_MINOR)) else {
            throw LoadError.incompatible(major: runtimeVersion.major, minor: runtimeVersion.minor)
        }
        // Empty options: the embedded runtime, standard permission mode; the
        // host (this helper) owns the permission UX, so check_permissions
        // reports attribution "host".
        var created: OpaquePointer?
        var error = CuaDriverBuffer()
        guard create(nil, 0, &created, &error) == 0, let created else {
            throw LoadError.create(Self.take(&error, free))
        }
        self.library = library
        self.handle = created
    }

    public func listTools() async throws -> Data {
        var json = CuaDriverBuffer()
        var error = CuaDriverBuffer()
        guard list(handle, &json, &error) == 0 else { throw ToolError(Self.take(&error, free)) }
        _ = Self.take(&error, free)
        return Data(Self.take(&json, free).utf8)
    }

    public func invoke(name: String, arguments: Data) async throws -> Data {
        let free = self.free
        let release = self.release
        return try await withCheckedThrowingContinuation { continuation in
            let box = Unmanaged.passRetained(CompletionBox(continuation: continuation, free: free))
            var operation: OpaquePointer?
            var error = CuaDriverBuffer()
            let nameBytes = Array(name.utf8)
            let argumentBytes = [UInt8](arguments)
            let status = invokeFn(handle, nameBytes, nameBytes.count, argumentBytes, argumentBytes.count,
                                  { context, status, result, error in
                                      let box = Unmanaged<CompletionBox>.fromOpaque(context!).takeRetainedValue()
                                      box.complete(status: status, result: result, error: error)
                                  },
                                  box.toOpaque(), &operation, &error)
            if status != 0 {
                box.release()
                continuation.resume(throwing: ToolError(Self.take(&error, free)))
            } else {
                // The completion owns the result; the token is released now
                // (cancellation is not used in phase 1).
                release(&operation)
            }
        }
    }

    static func take(_ buffer: inout CuaDriverBuffer, _ free: FreeFn) -> String {
        defer { free(&buffer) }
        guard let data = buffer.data, buffer.len > 0 else { return "" }
        return String(decoding: UnsafeBufferPointer(start: data, count: buffer.len), as: UTF8.self)
    }

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

/// Stands in when the library did not load: every call fails with the reason.
public struct UnavailableTools: ToolInvoking {
    public let reason: String
    public init(reason: String) { self.reason = reason }
    public func listTools() async throws -> Data { throw ToolError(reason) }
    public func invoke(name: String, arguments: Data) async throws -> Data { throw ToolError(reason) }
}
