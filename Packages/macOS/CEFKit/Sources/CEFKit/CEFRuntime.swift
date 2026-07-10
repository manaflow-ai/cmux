import CCEF
import Foundation

/// libcef entry points resolved with dlsym after CEFLibraryLoader dlopens the
/// framework. Host apps therefore need no special linker flags to embed
/// CEFKit; nothing links against libcef at build time. Handler structs and
/// types still come from the CCEF headers, so signatures stay checked against
/// the exact CEF distribution.
enum CEFRuntime {
    typealias InitializeFn = @convention(c) (
        UnsafePointer<cef_main_args_t>?,
        UnsafePointer<cef_settings_t>?,
        UnsafeMutablePointer<cef_app_t>?,
        UnsafeMutableRawPointer?
    ) -> Int32
    typealias ExecuteProcessFn = @convention(c) (
        UnsafePointer<cef_main_args_t>?,
        UnsafeMutablePointer<cef_app_t>?,
        UnsafeMutableRawPointer?
    ) -> Int32
    typealias ShutdownFn = @convention(c) () -> Void
    typealias DoMessageLoopWorkFn = @convention(c) () -> Void
    typealias ApiHashFn = @convention(c) (Int32, Int32) -> UnsafePointer<CChar>?
    typealias CreateBrowserFn = @convention(c) (
        UnsafePointer<cef_window_info_t>?,
        UnsafeMutablePointer<cef_client_t>?,
        UnsafePointer<cef_string_t>?,
        UnsafePointer<cef_browser_settings_t>?,
        UnsafeMutablePointer<cef_dictionary_value_t>?,
        UnsafeMutablePointer<cef_request_context_t>?
    ) -> Int32
    typealias CreateRequestContextFn = @convention(c) (
        UnsafePointer<cef_request_context_settings_t>?,
        UnsafeMutablePointer<cef_request_context_handler_t>?
    ) -> UnsafeMutablePointer<cef_request_context_t>?
    typealias StringUserfreeUtf16FreeFn = @convention(c) (cef_string_userfree_utf16_t?) -> Void

    static let initialize: InitializeFn = resolve("cef_initialize")
    static let executeProcess: ExecuteProcessFn = resolve("cef_execute_process")
    static let shutdown: ShutdownFn = resolve("cef_shutdown")
    static let doMessageLoopWork: DoMessageLoopWorkFn = resolve("cef_do_message_loop_work")
    static let apiHash: ApiHashFn = resolve("cef_api_hash")
    static let createBrowser: CreateBrowserFn = resolve("cef_browser_host_create_browser")
    static let createRequestContext: CreateRequestContextFn = resolve("cef_request_context_create_context")
    static let stringUserfreeUtf16Free: StringUserfreeUtf16FreeFn = resolve("cef_string_userfree_utf16_free")

    private static func resolve<F>(_ name: String) -> F {
        precondition(
            CEFLibraryLoader.isLoaded,
            "CEFKit: \(name) used before the CEF framework was loaded"
        )
        guard let symbol = dlsym(dlopen(nil, RTLD_LAZY), name) else {
            fatalError("CEFKit: missing libcef symbol \(name)")
        }
        return unsafeBitCast(symbol, to: F.self)
    }
}
