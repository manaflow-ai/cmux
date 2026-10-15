import Darwin
import Foundation

/// The C ABI of `libcmux_cef_shim.dylib`, resolved with `dlsym`.
///
/// Mirrors `Sources/CmuxCEF/Shim/cmux_cef_shim.h`; the shim must
/// have the same ABI identity (`CEFShimABI`). The shim
/// is loaded only when the first CEF tab is created, so a session without CEF
/// tabs never maps the shim or the 367 MiB Chromium framework, and SwiftPM
/// builds need no CEF headers.
/// Immutable C function pointers: safe to hand from the loading thread to the
/// main thread.
public struct CEFShimLibrary: @unchecked Sendable {
    public typealias ScheduleFn = @convention(c) (UnsafeMutableRawPointer?, Int64) -> Void
    public typealias EventFn = @convention(c) (
        UnsafeMutableRawPointer?, Int32, Int32, Int32, Int64, Int64,
        UnsafePointer<CChar>?, UnsafePointer<CChar>?
    ) -> Void
    public typealias KeyFn = @convention(c) (UnsafeMutableRawPointer?, Int32, UnsafeMutableRawPointer?) -> Int32
    /// `cmux_shim_window_request_fn`: ctx, kind, disposition, source,
    /// has_bounds, x, y, width, height, user gesture, url, profile path ->
    /// anchor browser.
    public typealias WindowRequestFn = @convention(c) (
        UnsafeMutableRawPointer?, Int32, Int32, Int32, Int32, Int32, Int32, Int32, Int32, Int32,
        UnsafePointer<CChar>?, UnsafePointer<CChar>?
    ) -> Int32
    /// `cmux_shim_focus_request_fn`: ctx, browser, source -> 1 allow.
    public typealias FocusRequestFn = @convention(c) (UnsafeMutableRawPointer?, Int32, Int32) -> Int32

    public let abiIDFn: @convention(c) () -> UnsafePointer<CChar>?
    public let load: @convention(c) (UnsafePointer<CChar>?, UnsafeMutablePointer<CChar>?, Int) -> Int32
    public let forkAPIVersion: @convention(c) () -> Int32
    public let prepareApplication: @convention(c) () -> Int32
    public let setExtensionDeveloperMode: @convention(c) (Int32) -> Void
    public let setBackgroundColor: @convention(c) (UInt32) -> Void
    public let browserSetBackgroundColor: @convention(c) (Int32, UInt32) -> Int32
    public let initialize: @convention(c) (
        UnsafePointer<CChar>?, UnsafePointer<CChar>?, UnsafePointer<CChar>?, UnsafePointer<CChar>?,
        UnsafePointer<CChar>?, Int32, UnsafePointer<CChar>?, UnsafePointer<CChar>?,
        UnsafePointer<UnsafePointer<CChar>?>?,
        UnsafeMutableRawPointer?, ScheduleFn?, EventFn?, KeyFn?
    ) -> Int32
    public let doWork: @convention(c) () -> Void

    public let createWindow: @convention(c) (Int32, UnsafeMutableRawPointer?, Int32, Int32, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Int32
    public let tabAdd: @convention(c) (Int32, UnsafePointer<CChar>?, Int32, Int32) -> Int32
    public let tabDuplicate: @convention(c) (Int32, Int32, Int32) -> Int32
    public let tabActivate: @convention(c) (Int32) -> Int32
    public let tabNavigationEntries: @convention(c) (Int32) -> UnsafeMutablePointer<CChar>?
    public let tabGoToEntry: @convention(c) (Int32, Int32) -> Int32
    public let tabWindowID: @convention(c) (Int32) -> Int32

    public let loadURL: @convention(c) (Int32, UnsafePointer<CChar>?) -> Void
    public let goBack: @convention(c) (Int32) -> Void
    public let goForward: @convention(c) (Int32) -> Void
    public let reload: @convention(c) (Int32) -> Void
    public let stop: @convention(c) (Int32) -> Void
    public let setFocus: @convention(c) (Int32, Int32) -> Void
    public let setZoomLevel: @convention(c) (Int32, Double) -> Void
    /// Chromium's print preview over the page; 0 when the browser is gone.
    public let printPage: @convention(c) (Int32) -> Int32
    public let find: @convention(c) (Int32, Int32, UnsafePointer<CChar>?, Int32, Int32, Int32) -> Void
    public let stopFinding: @convention(c) (Int32, Int32) -> Void
    public let close: @convention(c) (Int32) -> Void
    public let devToolsCall: @convention(c) (Int32, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Int32
    /// Raw DevTools protocol (`CEFDevToolsRawMessage`): watch a browser's
    /// events, send a message with an id from 2^30 (1 sent, 0 gone, -1 refused).
    public let devToolsWatchEvents: @convention(c) (Int32, Int32) -> Void
    public let devToolsSend: @convention(c) (Int32, UnsafePointer<CChar>?) -> Int32

    /// `cmux_shim_devtools_command_t`.
    public enum DevToolsCommand {
        public static let show: Int32 = 1
        public static let console: Int32 = 2
        public static let inspect: Int32 = 3
        public static let inspectAt: Int32 = 4
        public static let close: Int32 = 5
    }

    public let devToolsSetKeyHandler: @convention(c) (KeyFn?) -> Void
    public let devToolsSetPlacement: @convention(c) (Int32, UnsafeMutableRawPointer?, Int32, Int32, Int32, Int32) -> Void
    public let devToolsCommand: @convention(c) (Int32, Int32, Int32, Int32) -> Int32
    public let devToolsBrowser: @convention(c) (Int32) -> Int32
    public let devToolsSetFocus: @convention(c) (Int32, Int32) -> Void

    public let extActions: @convention(c) (Int32, Int32) -> UnsafeMutablePointer<CChar>?
    public let extActionRun: @convention(c) (Int32, UnsafePointer<CChar>?, Int32, Int32) -> Int32
    public let extActionHidePopup: @convention(c) (Int32, UnsafePointer<CChar>?) -> Void
    public let extActionContextMenu: @convention(c) (Int32, UnsafePointer<CChar>?, Int32, Int32) -> Void
    public let free: @convention(c) (UnsafeMutablePointer<CChar>?) -> Void
    public let tabNavigationState: @convention(c) (Int32) -> UnsafeMutablePointer<CChar>?
    public let tabRestoreNavigation: @convention(c) (Int32, UnsafePointer<CChar>?) -> Int32
    public let navigationRestoreSupported: @convention(c) () -> Int32
    // Fork API v3 (the shim returns 0/NULL on older forks).
    public let extList: @convention(c) (Int32) -> UnsafeMutablePointer<CChar>?
    public let extSetEnabled: @convention(c) (Int32, UnsafePointer<CChar>?, Int32) -> Int32
    public let extUninstall: @convention(c) (Int32, UnsafePointer<CChar>?) -> Int32
    public let extReload: @convention(c) (Int32, UnsafePointer<CChar>?) -> Int32
    public let extMovePinned: @convention(c) (Int32, UnsafePointer<CChar>?, Int32) -> Int32
    public let extSetPinned: @convention(c) (Int32, UnsafePointer<CChar>?, Int32) -> Int32
    public let extOpenOptions: @convention(c) (Int32, UnsafePointer<CChar>?) -> Int32
    public let extLoadUnpacked: @convention(c) (Int32, UnsafePointer<CChar>?) -> Int32
    public let extCommands: @convention(c) (Int32) -> UnsafeMutablePointer<CChar>?
    public let extCommandRun: @convention(c) (Int32, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Int32
    public let tabMoveToWindow: @convention(c) (Int32, Int32, Int32) -> Int32
    public let contextMenuDone: @convention(c) (Int32, Int32, Int32) -> Void
    /// Answers a renderer hang: 0 waits, 1 ends the renderer.
    public let unresponsiveReply: @convention(c) (Int32, Int32) -> Int32

    public let closeAll: @convention(c) () -> Void
    public let liveBrowserCount: @convention(c) () -> Int32
    public let windowCount: @convention(c) () -> Int32
    public let shutdown: @convention(c) () -> Void
    /// Chromium never shows a window of its own (fork API 8; no-op before).
    public let setWindowRequestHandler: @convention(c) (WindowRequestFn?) -> Void
    /// Chromium's own focus requests go through cmux (`CefFocusHandler`).
    public let setFocusRequestHandler: @convention(c) (FocusRequestFn?) -> Void
    /// Browsers Chromium created outside cmux (fork API 8; -1 before).
    public let foreignBrowserCount: @convention(c) () -> Int32
    /// Downloads (`CEFDownloads`): start one with a tab's context, answer
    /// DOWNLOAD_STARTED with a path ("" cancels), cancel/pause/resume.
    public let downloadURL: @convention(c) (Int32, UnsafePointer<CChar>?) -> Int32
    public let downloadContinue: @convention(c) (Int32, UnsafePointer<CChar>?) -> Int32
    public let downloadControl: @convention(c) (Int32, Int32) -> Int32
    /// Answers PERMISSION_PROMPT: 1 allow, 2 deny, else no answer.
    public let permissionContinue: @convention(c) (Int32, Int32) -> Int32

    // Page Info site state (ABI 3).
    public let contentSetting: @convention(c) (Int32, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Int32
    public let setContentSetting: @convention(c) (Int32, UnsafePointer<CChar>?, UnsafePointer<CChar>?, Int32) -> Int32
    public let visitCookies: @convention(c) (Int32, Int32) -> Int32
    public let deleteCookies: @convention(c) (Int32, Int32, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Int32
    /// A tab's favicon through its own request context (``CEFRuntime/favicon(_:url:maxPixels:)``).
    public let downloadFavicon: @convention(c) (Int32, Int32, UnsafePointer<CChar>?, Int32) -> Int32
    /// Browser import: cookies into a profile's request context.
    public let importCookies: @convention(c) (UnsafePointer<CChar>?, Int32, UnsafePointer<CChar>?) -> Int32
    public let clearCookies: @convention(c) (UnsafePointer<CChar>?, Int32, Int64) -> Int32
    /// Browser import: saved passwords into a profile's password store
    /// (entries as raw `cmux_shim_password_entry` rows, see CEFRuntime+PasswordImport).
    public let importPasswords: @convention(c) (UnsafePointer<CChar>?, Int32, UnsafeRawPointer?, Int32) -> Int32
    public let passwordEntrySize: @convention(c) () -> Int32
    public let passwordImportAvailable: @convention(c) () -> Int32
    public let replacePasswords: @convention(c) (UnsafePointer<CChar>?, Int32, UnsafeRawPointer?, Int32) -> Int32
    public let passwordReplaceAvailable: @convention(c) () -> Int32
    public let passwordPromptAnswer: @convention(c) (Int32, Int32, UnsafePointer<CChar>?) -> Int32
    public let setPasswordGenerationEnabled: @convention(c) (Int32) -> Int32
    /// Password filling on or off in one tab (off while an agent drives it).
    public let setPasswordFill: @convention(c) (Int32, Int32) -> Int32
    /// Profile (Touch ID) passkeys, metadata only (fork API 18; see CEFRuntime+Passkeys).
    public let passkeysAvailable: @convention(c) () -> Int32
    public let passkeysList: @convention(c) (UnsafePointer<CChar>?, Int32) -> Int32
    public let passkeyDelete: @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?, Int32) -> Int32
    /// Password manager core (fork API 18; see CEFEngine+Passwords). The reveal callback gets
    /// the bytes in a shim buffer that is zeroed after it returns.
    public typealias PasswordRevealCallback = @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?, Int) -> Void
    public let passwordCoreAvailable: @convention(c) () -> Int32
    public let passwordList: @convention(c) (UnsafePointer<CChar>?, Int32) -> Int32
    public let passwordRemove: @convention(c) (UnsafePointer<CChar>?, UnsafePointer<UnsafePointer<CChar>?>?, Int32, Int32) -> Int32
    public let passwordExceptionRemove: @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?, Int32) -> Int32
    public let passwordSetUsername: @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?, UnsafePointer<CChar>?, Int32) -> Int32
    public let passwordReveal: @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?, PasswordRevealCallback?, UnsafeMutableRawPointer?) -> Int32
    public let passwordExport: @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?, Int32) -> Int32
    public let sslStatus: @convention(c) (Int32) -> UnsafeMutablePointer<CChar>?
    /// Clears the profile's certificate error decisions and connections.
    public let clearCertificateExceptions: @convention(c) (Int32, Int32) -> Int32
    /// Answers the browser's next certificate error `code` on `host`:
    /// continue (0), or let Chromium's own interstitial decide (1); 0 when
    /// the browser is gone.
    public let certificateProceed: @convention(c) (Int32, UnsafePointer<CChar>?, Int32, Int32) -> Int32
    public let freeOwned: @convention(c) (UnsafeMutablePointer<CChar>?) -> Void
    /// Distinct renderer client ids hosting the tab's frames.
    public let rendererClientIDs: @convention(c) (Int32, UnsafeMutablePointer<Int32>?, Int32) -> Int32

    // Remote localhost (plans/cmux-next/remote-localhost.md).
    public let setContextProxy: @convention(c) (UnsafePointer<CChar>?, Int32) -> Int32
    public let contextProxyState: @convention(c) (UnsafePointer<CChar>?) -> Int32
    public let releaseContext: @convention(c) (UnsafePointer<CChar>?) -> Void
    public let setNavigationGuard: @convention(c) (Int32, Int32) -> Void
    /// A sign-in tab's callback: scheme, https host, https path (all empty clears).
    public let setAuthCallback: @convention(c) (Int32, UnsafePointer<CChar>?, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Void

    // Allowlisted boolean profile preferences (password and autofill settings).
    /// JSON {"value", "modifiable"}, freed with `freeOwned`; NULL for an
    /// unknown profile or a name not allowed.
    public let prefGet: @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>?
    /// 1 set, 0 not modifiable or not allowed, -1 refused.
    public let prefSetBool: @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?, Int32) -> Int32
    public let prefWatch: @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?, Int32) -> Int32
    /// The chrome.bookmarks bridge: profile cache path, tree JSON; 1, 0 not loaded, -1 refused.
    public let bookmarksSync: @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Int32
    /// cmux-page://<id>/ from a folder: id, resource root, CSP (NULL = default).
    public let pageSchemeAdd: @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Int32
    /// The same for reserved (`cmux.`) ids only: the first-party path (`CEFPageSchemes`).
    public let pageSchemeAddFirstParty: @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Int32

    // Extension UI the app draws (fork API 12; no-ops and 0/NULL before).
    public let setNewTabPageURL: @convention(c) (UnsafePointer<CChar>?) -> Void
    public let addNativeMessagingDir: @convention(c) (UnsafePointer<CChar>?, Int32) -> Int32
    public let installPromptReply: @convention(c) (Int32, Int32) -> Int32
    public let omniboxKeywords: @convention(c) (Int32) -> UnsafeMutablePointer<CChar>?
    public let omniboxInput: @convention(c) (Int32, UnsafePointer<CChar>?, Int32, UnsafePointer<CChar>?, Int32) -> Int32
    // Popup windows (fork API 11): exposed for the popup panel; not enabled yet.
    public let setPopupWindowsEnabled: @convention(c) (Int32) -> Void
    public let popupWindowBounds: @convention(c) (Int32, UnsafeMutablePointer<Int32>?, UnsafeMutablePointer<Int32>?,
                                           UnsafeMutablePointer<Int32>?, UnsafeMutablePointer<Int32>?) -> Int32
    public let popupWindowAttach: @convention(c) (Int32, UnsafeMutableRawPointer?, Int32, Int32) -> Int32
    // Side panel header (fork API 13).
    public let sidePanelState: @convention(c) (Int32) -> UnsafeMutablePointer<CChar>?
    public let sidePanelPress: @convention(c) (Int32, UnsafePointer<CChar>?) -> Int32

    public enum LoadError: Error, Equatable, Sendable {
        case open(String)
        case missingSymbol(String)
        /// Identities are SHA-256 hex strings of the header (`CEFShimABI`).
        case abiMismatch(expected: String, found: String)
    }

    /// Checks the shim's identity against the header this code was built with.
    static func checkABI(expected: String?, found: String?) throws(LoadError) {
        guard let expected, let found, expected == found else {
            throw .abiMismatch(expected: expected ?? "missing", found: found ?? "missing")
        }
    }

    /// Opens the shim at `url`, resolves every symbol and checks that its ABI
    /// identity is `expected` (`CEFShimABI.bundledIdentity()`).
    static func open(_ url: URL, expected: String?) throws(LoadError) -> CEFShimLibrary {
        guard let handle = dlopen(url.path, RTLD_NOW | RTLD_LOCAL) else {
            throw .open(String(cString: dlerror()))
        }
        let resolver = Resolver(handle: handle)
        let library = try CEFShimLibrary(resolver)
        try checkABI(expected: expected, found: library.abiIDFn().map { String(cString: $0) })
        return library
    }

    private struct Resolver {
        let handle: UnsafeMutableRawPointer

        func callAsFunction<T>(_ name: String) throws(LoadError) -> T {
            guard let symbol = dlsym(handle, name) else { throw .missingSymbol(name) }
            return unsafeBitCast(symbol, to: T.self)
        }
    }

    private init(_ r: Resolver) throws(LoadError) {
        abiIDFn = try r("cmux_shim_abi_id")
        load = try r("cmux_shim_load")
        forkAPIVersion = try r("cmux_shim_fork_api_version")
        prepareApplication = try r("cmux_shim_prepare_application")
        setExtensionDeveloperMode = try r("cmux_shim_set_extension_developer_mode")
        setBackgroundColor = try r("cmux_shim_set_background_color")
        browserSetBackgroundColor = try r("cmux_shim_browser_set_background_color")
        initialize = try r("cmux_shim_initialize")
        doWork = try r("cmux_shim_do_work")
        createWindow = try r("cmux_shim_create_window")
        tabAdd = try r("cmux_shim_tab_add")
        tabDuplicate = try r("cmux_shim_tab_duplicate")
        tabActivate = try r("cmux_shim_tab_activate")
        tabNavigationEntries = try r("cmux_shim_tab_navigation_entries")
        tabGoToEntry = try r("cmux_shim_tab_go_to_entry")
        tabWindowID = try r("cmux_shim_tab_window_id")
        loadURL = try r("cmux_shim_load_url")
        goBack = try r("cmux_shim_go_back")
        goForward = try r("cmux_shim_go_forward")
        reload = try r("cmux_shim_reload")
        stop = try r("cmux_shim_stop")
        setFocus = try r("cmux_shim_set_focus")
        setZoomLevel = try r("cmux_shim_set_zoom_level")
        printPage = try r("cmux_shim_print")
        find = try r("cmux_shim_find")
        stopFinding = try r("cmux_shim_stop_finding")
        close = try r("cmux_shim_close")
        devToolsCall = try r("cmux_shim_devtools_call")
        devToolsWatchEvents = try r("cmux_shim_devtools_watch_events")
        devToolsSend = try r("cmux_shim_devtools_send")
        devToolsSetKeyHandler = try r("cmux_shim_devtools_set_key_handler")
        devToolsSetPlacement = try r("cmux_shim_devtools_set_placement")
        devToolsCommand = try r("cmux_shim_devtools_command")
        devToolsBrowser = try r("cmux_shim_devtools_browser")
        devToolsSetFocus = try r("cmux_shim_devtools_set_focus")
        extActions = try r("cmux_shim_ext_actions")
        extActionRun = try r("cmux_shim_ext_action_run")
        extActionHidePopup = try r("cmux_shim_ext_action_hide_popup")
        extActionContextMenu = try r("cmux_shim_ext_action_context_menu")
        free = try r("cmux_shim_free")
        tabNavigationState = try r("cmux_shim_tab_navigation_state")
        tabRestoreNavigation = try r("cmux_shim_tab_restore_navigation")
        navigationRestoreSupported = try r("cmux_shim_navigation_restore_supported")
        extList = try r("cmux_shim_ext_list")
        extSetEnabled = try r("cmux_shim_ext_set_enabled")
        extUninstall = try r("cmux_shim_ext_uninstall")
        extReload = try r("cmux_shim_ext_reload")
        extMovePinned = try r("cmux_shim_ext_move_pinned")
        extSetPinned = try r("cmux_shim_ext_set_pinned")
        extOpenOptions = try r("cmux_shim_ext_open_options")
        extLoadUnpacked = try r("cmux_shim_ext_load_unpacked")
        extCommands = try r("cmux_shim_ext_commands")
        extCommandRun = try r("cmux_shim_ext_command_run")
        tabMoveToWindow = try r("cmux_shim_tab_move_to_window")
        contextMenuDone = try r("cmux_shim_context_menu_done")
        unresponsiveReply = try r("cmux_shim_unresponsive_reply")
        closeAll = try r("cmux_shim_close_all")
        liveBrowserCount = try r("cmux_shim_live_browser_count")
        windowCount = try r("cmux_shim_window_count")
        shutdown = try r("cmux_shim_shutdown")
        setWindowRequestHandler = try r("cmux_shim_set_window_request_handler")
        setFocusRequestHandler = try r("cmux_shim_set_focus_request_handler")
        foreignBrowserCount = try r("cmux_shim_foreign_browser_count")
        downloadURL = try r("cmux_shim_download_url")
        downloadContinue = try r("cmux_shim_download_continue")
        downloadControl = try r("cmux_shim_download_control")
        permissionContinue = try r("cmux_shim_permission_continue")
        contentSetting = try r("cmux_shim_content_setting")
        setContentSetting = try r("cmux_shim_set_content_setting")
        visitCookies = try r("cmux_shim_visit_cookies")
        deleteCookies = try r("cmux_shim_delete_cookies")
        downloadFavicon = try r("cmux_shim_download_favicon")
        importCookies = try r("cmux_shim_import_cookies")
        clearCookies = try r("cmux_shim_clear_cookies")
        importPasswords = try r("cmux_shim_import_passwords")
        passwordEntrySize = try r("cmux_shim_password_entry_size")
        passwordImportAvailable = try r("cmux_shim_password_import_available")
        replacePasswords = try r("cmux_shim_replace_passwords")
        passwordReplaceAvailable = try r("cmux_shim_password_replace_available")
        passwordPromptAnswer = try r("cmux_shim_password_prompt_answer")
        setPasswordGenerationEnabled = try r("cmux_shim_set_password_generation_enabled")
        setPasswordFill = try r("cmux_shim_set_password_fill")
        passkeysAvailable = try r("cmux_shim_passkeys_available")
        passkeysList = try r("cmux_shim_passkeys_list")
        passkeyDelete = try r("cmux_shim_passkey_delete")
        passwordCoreAvailable = try r("cmux_shim_password_core_available")
        passwordList = try r("cmux_shim_password_list")
        passwordRemove = try r("cmux_shim_password_remove")
        passwordExceptionRemove = try r("cmux_shim_password_exception_remove")
        passwordSetUsername = try r("cmux_shim_password_set_username")
        passwordReveal = try r("cmux_shim_password_reveal")
        passwordExport = try r("cmux_shim_password_export")
        sslStatus = try r("cmux_shim_ssl_status")
        clearCertificateExceptions = try r("cmux_shim_clear_certificate_exceptions")
        certificateProceed = try r("cmux_shim_certificate_proceed")
        freeOwned = try r("cmux_shim_free_owned")
        rendererClientIDs = try r("cmux_shim_renderer_client_ids")
        setContextProxy = try r("cmux_shim_set_context_proxy")
        contextProxyState = try r("cmux_shim_context_proxy_state")
        releaseContext = try r("cmux_shim_release_context")
        setNavigationGuard = try r("cmux_shim_set_navigation_guard")
        setAuthCallback = try r("cmux_shim_set_auth_callback")
        prefGet = try r("cmux_shim_pref_get")
        prefSetBool = try r("cmux_shim_pref_set_bool")
        prefWatch = try r("cmux_shim_pref_watch")
        bookmarksSync = try r("cmux_shim_bookmarks_sync")
        pageSchemeAdd = try r("cmux_shim_page_scheme_add")
        pageSchemeAddFirstParty = try r("cmux_shim_page_scheme_add_first_party")
        setNewTabPageURL = try r("cmux_shim_set_new_tab_page_url")
        addNativeMessagingDir = try r("cmux_shim_add_native_messaging_dir")
        installPromptReply = try r("cmux_shim_install_prompt_reply")
        omniboxKeywords = try r("cmux_shim_omnibox_keywords")
        omniboxInput = try r("cmux_shim_omnibox_input")
        setPopupWindowsEnabled = try r("cmux_shim_set_popup_windows_enabled")
        popupWindowBounds = try r("cmux_shim_popup_window_bounds")
        popupWindowAttach = try r("cmux_shim_popup_window_attach")
        sidePanelState = try r("cmux_shim_side_panel_state")
        sidePanelPress = try r("cmux_shim_side_panel_press")
    }

    /// Returns a string the shim allocated itself (`cmux_shim_ssl_status`)
    /// and frees it.
    public func takeOwnedString(_ pointer: UnsafeMutablePointer<CChar>?) -> String? {
        guard let pointer else { return nil }
        defer { freeOwned(pointer) }
        return String(cString: pointer)
    }

    /// Returns a fork string as Swift and frees it.
    public func takeString(_ pointer: UnsafeMutablePointer<CChar>?) -> String? {
        guard let pointer else { return nil }
        defer { free(pointer) }
        return String(cString: pointer)
    }
}
