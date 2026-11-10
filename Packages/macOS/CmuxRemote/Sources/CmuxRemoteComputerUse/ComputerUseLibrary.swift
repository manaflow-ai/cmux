// SPDX-License-Identifier: GPL-3.0-or-later
import CCmuxComputerUse
import Darwin
import Foundation

/// libcmux_computer_use.dylib (cmux-tui/crates/cmux-computer-use-ffi, C ABI v1), opened with
/// dlopen from cmux Remote's Frameworks so this package builds without it. Only the worker
/// calls it; every call that blocks runs off the main thread.
final class ComputerUseLibrary: @unchecked Sendable { // crash-allow: immutable after init; the C functions are thread-safe (header contract)
    typealias AbiVersionFn = @convention(c) () -> UInt32
    typealias CreateFn = @convention(c) (UnsafePointer<UInt8>?, Int, UnsafePointer<UInt8>?, Int, UnsafePointer<UInt8>?, Int,
                                         UnsafePointer<CmuxCuHost>?, UnsafeMutablePointer<CmuxCuBuffer>?) -> OpaquePointer?
    typealias DestroyFn = @convention(c) (OpaquePointer?) -> Void
    typealias SetConfigFn = @convention(c) (OpaquePointer?, UnsafePointer<UInt8>?, Int, UnsafeMutablePointer<CmuxCuBuffer>?) -> Int32
    typealias SavedApprovalsFn = @convention(c) (OpaquePointer?) -> CmuxCuBuffer
    typealias EditApprovalsFn = @convention(c) (OpaquePointer?, UnsafePointer<UInt8>?, Int, UnsafePointer<UInt8>?, Int) -> Int32
    typealias SessionFn = @convention(c) (OpaquePointer?, UnsafePointer<UInt8>?, Int, UnsafePointer<UInt8>?, Int,
                                          UnsafePointer<UInt8>?, Int) -> Int32
    typealias FreeFn = @convention(c) (CmuxCuBuffer) -> Void
    /// `void *cmux_cu_serve(CmuxCuEngine *, const uint8_t *socket_path, size_t, const uint8_t *secret_hex, size_t,
    /// CmuxCuBuffer *error)`: serves the agent socket (`cmux_computer_use::server`,
    /// cmux-computer-use-v1) at `socket_path` on the library's own threads, admitting this user's
    /// peers that present the secret. Returns a handle, or NULL with `error` filled.
    typealias ServeFn = @convention(c) (OpaquePointer?, UnsafePointer<UInt8>?, Int, UnsafePointer<UInt8>?, Int,
                                        UnsafeMutablePointer<CmuxCuBuffer>?) -> UnsafeMutableRawPointer?
    /// `void cmux_cu_serve_stop(void *handle)`: stops serving and frees the handle.
    typealias ServeStopFn = @convention(c) (UnsafeMutableRawPointer?) -> Void

    enum LoadError: Error, CustomStringConvertible, Equatable {
        case open(String)
        case symbol(String)
        case version(UInt32)

        var description: String {
            switch self {
            case .open(let message): "cannot open libcmux_computer_use: \(message)"
            case .symbol(let name): "libcmux_computer_use lacks \(name)"
            case .version(let found): "libcmux_computer_use speaks ABI \(found), this worker \(CMUX_CU_ABI_VERSION)"
            }
        }
    }

    let create: CreateFn
    let destroy: DestroyFn
    let setConfig: SetConfigFn
    let savedApprovals: SavedApprovalsFn
    let editApprovals: EditApprovalsFn
    let session: SessionFn
    let free: FreeFn
    let serve: ServeFn
    let serveStop: ServeStopFn

    /// The library in this bundle's Frameworks (a plain dylib, never a nested .framework).
    static func bundledPath(bundle: Bundle = .main) -> String {
        (bundle.privateFrameworksPath ?? (bundle.bundlePath + "/Contents/Frameworks")) + "/libcmux_computer_use.dylib"
    }

    init(path: String) throws {
        guard let handle = dlopen(path, RTLD_NOW | RTLD_LOCAL) else {
            throw LoadError.open(dlerror().map { String(cString: $0) } ?? path)
        }
        func symbol<T>(_ name: String, _: T.Type) throws -> T {
            guard let pointer = dlsym(handle, name) else { throw LoadError.symbol(name) }
            return unsafeBitCast(pointer, to: T.self)
        }
        let version = try symbol("cmux_cu_abi_version", AbiVersionFn.self)()
        guard version == UInt32(CMUX_CU_ABI_VERSION) else { throw LoadError.version(version) }
        create = try symbol("cmux_cu_engine_create", CreateFn.self)
        destroy = try symbol("cmux_cu_engine_destroy", DestroyFn.self)
        setConfig = try symbol("cmux_cu_engine_set_config", SetConfigFn.self)
        savedApprovals = try symbol("cmux_cu_engine_saved_approvals", SavedApprovalsFn.self)
        editApprovals = try symbol("cmux_cu_engine_edit_approvals", EditApprovalsFn.self)
        session = try symbol("cmux_cu_engine_session", SessionFn.self)
        free = try symbol("cmux_cu_buffer_free", FreeFn.self)
        serve = try symbol("cmux_cu_serve", ServeFn.self)
        serveStop = try symbol("cmux_cu_serve_stop", ServeStopFn.self)
    }

    /// A library buffer as a string, freed.
    func take(_ buffer: CmuxCuBuffer) -> String {
        defer { if buffer.data != nil { free(buffer) } }
        guard let data = buffer.data, buffer.len > 0 else { return "" }
        return String(decoding: UnsafeBufferPointer(start: data, count: buffer.len), as: UTF8.self)
    }
}

/// One engine (`cmux_cu_engine_create`), alive for the worker's life.
final class ComputerUseEngine: @unchecked Sendable { // crash-allow: the handle is immutable; the engine is thread-safe (header contract)
    let library: ComputerUseLibrary
    private let handle: OpaquePointer

    struct Failure: Error, CustomStringConvertible, Equatable {
        let description: String
    }

    /// `host` must outlive the engine (its context is the worker's services, kept for the process's life).
    init(library: ComputerUseLibrary, policy: Data, stateDirectory: String, machine: String,
         host: UnsafePointer<CmuxCuHost>) throws {
        self.library = library
        var error = CmuxCuBuffer(data: nil, len: 0)
        let created = policy.withBytes { config in
            Array(stateDirectory.utf8).withUnsafeBufferPointer { state in
                Array(machine.utf8).withUnsafeBufferPointer { name in
                    library.create(config.baseAddress, config.count, state.baseAddress, state.count,
                                   name.baseAddress, name.count, host, &error)
                }
            }
        }
        guard let created else {
            let message = library.take(error)
            throw Failure(description: message.isEmpty ? "cmux_cu_engine_create failed" : message)
        }
        handle = created
    }

    func setConfig(_ policy: Data) throws {
        var error = CmuxCuBuffer(data: nil, len: 0)
        let status = policy.withBytes { library.setConfig(handle, $0.baseAddress, $0.count, &error) }
        guard status == 0 else { throw Failure(description: library.take(error)) }
    }

    /// `{"always":[...],"never":[...]}`.
    func savedApprovals() -> [String: Any] {
        let text = library.take(library.savedApprovals(handle))
        return (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:]
    }

    func edit(action: String, appID: String) -> Bool {
        Array(action.utf8).withUnsafeBufferPointer { action in
            Array(appID.utf8).withUnsafeBufferPointer { app in
                library.editApprovals(handle, action.baseAddress, action.count, app.baseAddress, app.count) == 0
            }
        }
    }

    /// What `cmux_cu_engine_session` did.
    enum SessionResult: Int32, Sendable {
        case changed = 0
        case refused = 1
        case unchanged = 2
    }

    /// Stops or resumes agent session `control.session` (the person's menu bar Stop and Resume).
    func apply(_ control: SessionControl) -> SessionResult {
        let status = Array(control.action.rawValue.utf8).withUnsafeBufferPointer { action in
            Array(control.session.utf8).withUnsafeBufferPointer { session in
                Array(control.label.utf8).withUnsafeBufferPointer { label in
                    library.session(handle, action.baseAddress, action.count, session.baseAddress, session.count,
                                    label.baseAddress, label.count)
                }
            }
        }
        return SessionResult(rawValue: status) ?? .refused
    }

    /// Serves the agent socket at `socket` (the library's threads); the server stops with ``stopServing(_:)``.
    func serve(socket: String, secret: String) throws -> ServerHandle {
        var error = CmuxCuBuffer(data: nil, len: 0)
        let handle = Array(socket.utf8).withUnsafeBufferPointer { path in
            Array(secret.utf8).withUnsafeBufferPointer { secret in
                library.serve(self.handle, path.baseAddress, path.count, secret.baseAddress, secret.count, &error)
            }
        }
        guard let handle else {
            let message = library.take(error)
            throw Failure(description: message.isEmpty ? "cmux_cu_serve failed" : message)
        }
        return ServerHandle(raw: handle)
    }

    func stopServing(_ server: ServerHandle) {
        library.serveStop(server.raw)
    }

    deinit { library.destroy(handle) }
}

/// A running agent socket server (`cmux_cu_serve`'s handle).
struct ServerHandle: @unchecked Sendable { // crash-allow: an opaque handle the library owns; only passed back to cmux_cu_serve_stop
    let raw: UnsafeMutableRawPointer
}

extension Data {
    /// The bytes as a typed buffer for one C call.
    func withBytes<R>(_ body: (UnsafeBufferPointer<UInt8>) throws -> R) rethrows -> R {
        try withUnsafeBytes { try body($0.bindMemory(to: UInt8.self)) }
    }
}
