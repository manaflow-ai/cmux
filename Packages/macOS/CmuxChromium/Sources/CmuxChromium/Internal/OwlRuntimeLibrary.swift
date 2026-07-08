import COwlFreshRuntime
import Foundation

/// Typed `dlsym` bindings to `libowl_fresh_mojo_runtime.dylib`.
///
/// The dylib is loaded at runtime from a downloaded runtime bundle, never
/// linked. Instances are created and used exclusively on the pinned runtime
/// thread owned by `ChromiumRuntimeExecutor`.
final class OwlRuntimeLibrary {
    typealias ErrorOut = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
    typealias StringOut = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?

    typealias GlobalInitFn = @convention(c) () -> Int32
    typealias SessionCreateFn = @convention(c) (
        UnsafePointer<CChar>?, UnsafePointer<CChar>?, UnsafePointer<CChar>?,
        OwlFreshMojoEventCallback?, UnsafeMutableRawPointer?
    ) -> OpaquePointer?
    typealias SessionCreateWithProxyFn = @convention(c) (
        UnsafePointer<CChar>?, UnsafePointer<CChar>?, UnsafePointer<CChar>?, UnsafePointer<CChar>?,
        OwlFreshMojoEventCallback?, UnsafeMutableRawPointer?
    ) -> OpaquePointer?
    typealias SessionDestroyFn = @convention(c) (OpaquePointer?) -> Void
    typealias SessionHostPIDFn = @convention(c) (OpaquePointer?) -> Int32
    typealias SessionBindFn = @convention(c) (OpaquePointer?, UInt64, ErrorOut) -> Int32
    typealias SessionFlushFn = @convention(c) (OpaquePointer?, UnsafeMutablePointer<Bool>?, ErrorOut) -> Int32
    typealias JavaScriptFn = @convention(c) (OpaquePointer?, UnsafePointer<CChar>?, StringOut, ErrorOut) -> Int32
    typealias NavigateFn = @convention(c) (OpaquePointer?, UnsafePointer<CChar>?, ErrorOut) -> Int32
    typealias ResizeFn = @convention(c) (OpaquePointer?, UInt32, UInt32, Float, ErrorOut) -> Int32
    typealias SetFocusFn = @convention(c) (OpaquePointer?, Bool, ErrorOut) -> Int32
    typealias SendMouseFn = @convention(c) (
        OpaquePointer?, UInt32, Float, Float, UInt32, UInt32, Float, Float, UInt32, ErrorOut
    ) -> Int32
    typealias SendKeyFn = @convention(c) (OpaquePointer?, Bool, UInt32, UnsafePointer<CChar>?, UInt32, ErrorOut) -> Int32
    typealias DevToolsOpenFn = @convention(c) (OpaquePointer?, UInt32, UnsafeMutablePointer<Bool>?, ErrorOut) -> Int32
    typealias DevToolsCloseFn = @convention(c) (OpaquePointer?, UnsafeMutablePointer<Bool>?, ErrorOut) -> Int32
    typealias CaptureJSONFn = @convention(c) (OpaquePointer?, StringOut, ErrorOut) -> Int32
    typealias PollEventsFn = @convention(c) (UInt32) -> Void
    typealias FreeBufferFn = @convention(c) (UnsafeMutableRawPointer?) -> Void

    let globalInit: GlobalInitFn
    let sessionCreate: SessionCreateFn
    let sessionCreateWithProxy: SessionCreateWithProxyFn
    let sessionDestroy: SessionDestroyFn
    let sessionHostPID: SessionHostPIDFn
    let sessionSetClient: SessionBindFn
    let sessionBindProfile: SessionBindFn
    let sessionBindWebView: SessionBindFn
    let sessionBindInput: SessionBindFn
    let sessionBindSurfaceTree: SessionBindFn
    let sessionBindNativeSurfaceHost: SessionBindFn
    let sessionBindDevToolsHost: SessionBindFn
    let sessionFlush: SessionFlushFn
    let shellExecuteJavaScript: JavaScriptFn
    let navigate: NavigateFn
    let resize: ResizeFn
    let setFocus: SetFocusFn
    let sendMouse: SendMouseFn
    let sendKey: SendKeyFn
    let devToolsOpen: DevToolsOpenFn
    let devToolsClose: DevToolsCloseFn
    let devToolsEvaluateJavaScript: JavaScriptFn
    let captureSurfaceJSON: CaptureJSONFn
    let pollEvents: PollEventsFn
    let freeBuffer: FreeBufferFn

    /// Loads the dylib and resolves every required symbol.
    init(url: URL) throws {
        guard let handle = dlopen(url.path, RTLD_NOW | RTLD_LOCAL) else {
            let message = dlerror().map { String(cString: $0) } ?? "dlopen returned null"
            throw ChromiumRuntimeError.libraryLoadFailed(message)
        }
        func symbol<T>(_ name: String, as type: T.Type) throws -> T {
            guard let raw = dlsym(handle, name) else {
                throw ChromiumRuntimeError.symbolMissing(name)
            }
            return unsafeBitCast(raw, to: T.self)
        }
        globalInit = try symbol("owl_fresh_mojo_global_init", as: GlobalInitFn.self)
        sessionCreate = try symbol("owl_fresh_mojo_session_create", as: SessionCreateFn.self)
        sessionCreateWithProxy = try symbol("owl_fresh_mojo_session_create_with_proxy", as: SessionCreateWithProxyFn.self)
        sessionDestroy = try symbol("owl_fresh_mojo_session_destroy", as: SessionDestroyFn.self)
        sessionHostPID = try symbol("owl_fresh_mojo_session_host_pid", as: SessionHostPIDFn.self)
        sessionSetClient = try symbol("owl_fresh_mojo_session_set_client", as: SessionBindFn.self)
        sessionBindProfile = try symbol("owl_fresh_mojo_session_bind_profile", as: SessionBindFn.self)
        sessionBindWebView = try symbol("owl_fresh_mojo_session_bind_web_view", as: SessionBindFn.self)
        sessionBindInput = try symbol("owl_fresh_mojo_session_bind_input", as: SessionBindFn.self)
        sessionBindSurfaceTree = try symbol("owl_fresh_mojo_session_bind_surface_tree", as: SessionBindFn.self)
        sessionBindNativeSurfaceHost = try symbol("owl_fresh_mojo_session_bind_native_surface_host", as: SessionBindFn.self)
        sessionBindDevToolsHost = try symbol("owl_fresh_mojo_session_bind_devtools_host", as: SessionBindFn.self)
        sessionFlush = try symbol("owl_fresh_mojo_session_flush", as: SessionFlushFn.self)
        shellExecuteJavaScript = try symbol("owl_fresh_mojo_shell_execute_javascript", as: JavaScriptFn.self)
        navigate = try symbol("owl_fresh_mojo_web_view_navigate", as: NavigateFn.self)
        resize = try symbol("owl_fresh_mojo_web_view_resize", as: ResizeFn.self)
        setFocus = try symbol("owl_fresh_mojo_web_view_set_focus", as: SetFocusFn.self)
        sendMouse = try symbol("owl_fresh_mojo_input_send_mouse", as: SendMouseFn.self)
        sendKey = try symbol("owl_fresh_mojo_input_send_key", as: SendKeyFn.self)
        devToolsOpen = try symbol("owl_fresh_mojo_devtools_open", as: DevToolsOpenFn.self)
        devToolsClose = try symbol("owl_fresh_mojo_devtools_close", as: DevToolsCloseFn.self)
        devToolsEvaluateJavaScript = try symbol("owl_fresh_mojo_devtools_evaluate_javascript", as: JavaScriptFn.self)
        captureSurfaceJSON = try symbol("owl_fresh_mojo_surface_tree_capture_surface_json", as: CaptureJSONFn.self)
        pollEvents = try symbol("owl_fresh_mojo_poll_events", as: PollEventsFn.self)
        freeBuffer = try symbol("owl_fresh_mojo_free_buffer", as: FreeBufferFn.self)
    }

    /// Throws ``ChromiumRuntimeError/callFailed(_:)`` for a nonzero status,
    /// consuming (and freeing) the runtime-allocated error message.
    func throwIfFailed(_ status: Int32, _ error: UnsafeMutablePointer<CChar>?) throws {
        let message = takeString(error)
        guard status == 0 else {
            throw ChromiumRuntimeError.callFailed(message ?? "status \(status)")
        }
    }

    /// Copies a runtime-allocated C string and frees it via the runtime's allocator.
    func takeString(_ pointer: UnsafeMutablePointer<CChar>?) -> String? {
        guard let pointer else { return nil }
        defer { freeBuffer(pointer) }
        return String(cString: pointer)
    }
}
