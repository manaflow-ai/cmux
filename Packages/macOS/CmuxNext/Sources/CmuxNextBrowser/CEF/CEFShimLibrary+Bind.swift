import Darwin
import Foundation

// SAFETY (every `unsafe` in this file): `r` resolves each export of a shim whose ABI identity
// (`CEFShimABI`, the SHA-256 of cmux_cef_shim.h) matched, or a test's stand-in of the same C type,
// so each cast below is that export's C type in the header. A C string argument is the
// NUL-terminated buffer `withCString` gives for the call alone; the shim reads it during the call
// and copies what it keeps. A byte array argument is the array's own storage for the call alone,
// passed with its count; the shim copies the bytes before it returns. A returned string is the shim's own allocation, copied and then freed
// once with the free function cmux_cef_shim.h names for it (`take`).
nonisolated extension CEFShimLibrary {
    /// Every function from `r` (`open`; `resolving` and `overriding` in CEFShimLibrary+Resolver.swift).
    init(_ r: Resolver) throws(LoadError) {
        resolver = r
        let cFree: FreeFn = try unsafe r("cmux_shim_free")
        unsafe free = cFree
        let cFreeOwned: FreeFn = try unsafe r("cmux_shim_free_owned")
        let cAbiID: @convention(c) () -> UnsafePointer<CChar>? = try unsafe r("cmux_shim_abi_id")
        abiID = { unsafe cAbiID().map(String.init(cString:)) }
        let cLoadFramework: @convention(c) (UnsafePointer<CChar>?, UnsafeMutablePointer<CChar>?, Int) -> Int32 = try unsafe r("cmux_shim_load")
        loadFramework = { path in
            var message = [CChar](repeating: 0, count: 512)
            let capacity = message.count
            guard unsafe cLoadFramework(path, &message, capacity) != 1 else { return nil }
            return String(decoding: message.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        }
        forkAPIVersion = try r("cmux_shim_fork_api_version")
        prepareApplication = try r("cmux_shim_prepare_application")
        setExtensionDeveloperMode = try r("cmux_shim_set_extension_developer_mode")
        let cSetDefaultSearch: @convention(c) (UnsafePointer<CChar>?) -> Void = try unsafe r("cmux_shim_set_default_search")
        setDefaultSearch = { a0 in unsafe Self.withCString(a0) { s0 in unsafe cSetDefaultSearch(s0) } }
        let cSetChromePolicyID: @convention(c) (UnsafePointer<CChar>?) -> Void = try unsafe r("cmux_shim_set_chrome_policy_id")
        setChromePolicyID = { a0 in unsafe Self.withCString(a0) { s0 in unsafe cSetChromePolicyID(s0) } }
        setBackgroundColor = try r("cmux_shim_set_background_color")
        browserSetBackgroundColor = try r("cmux_shim_browser_set_background_color")
        tabSetTransparentBackground = try r("cmux_shim_tab_set_transparent_background")
        setFileDialogs = try r("cmux_shim_set_file_dialogs")
        let cFileDialogAnswer: @convention(c) (Int32, Int32, UnsafePointer<CChar>?) -> Int32 = try unsafe r("cmux_shim_file_dialog_answer")
        fileDialogAnswer = { a0, a1, a2 in unsafe Self.withCString(a2) { s2 in unsafe cFileDialogAnswer(a0, a1, s2) } }
        browserSetLayerHosting = try r("cmux_shim_browser_set_layer_hosting")
        browserSetResizeSync = try r("cmux_shim_browser_set_resize_sync")
        browserSetResizeFence = r.inProcess("cmux_shim_browser_set_resize_fence")
        browserSetEmbedderActive = try r("cmux_shim_browser_set_embedder_active")
        let cBrowserAccessibilityToken: @convention(c) (Int32, Int32, UnsafePointer<UInt8>?, Int32, UnsafePointer<UInt8>?, Int32,
                                                        UnsafeMutablePointer<UInt8>?, Int32) -> Int32 =
            try unsafe r("cmux_shim_browser_accessibility_token")
        browserAccessibilityToken = { browser, embedderPID, viewToken, windowToken, capacity in
            var buffer = [UInt8](repeating: 0, count: max(Int(capacity), 0))
            let room = Int32(buffer.count)
            // SAFETY: the shim reads each token's count bytes from its array's buffer and writes at most
            // `room` bytes into `buffer`, all during the call.
            let length = unsafe cBrowserAccessibilityToken(browser, embedderPID, viewToken, Int32(viewToken.count),
                                                           windowToken, Int32(windowToken.count), &buffer, room)
            return ChromiumHostAccessibilityToken(length: length, buffer: buffer)
        }
        browserSetEmbedderVisibility = r.optional("cmux_shim_browser_set_embedder_visibility")
        browserSetPageVisibility = try r("cmux_shim_browser_set_page_visibility")
        tabSetVisibility = r.optional("cmux_shim_tab_set_visibility")
        let cTabPagePush: (@convention(c) (Int32, UnsafePointer<CChar>?) -> Int32)? = unsafe r.optional("cmux_shim_tab_page_push")
        if let c = unsafe cTabPagePush {
            tabPagePush = { a0, a1 in unsafe Self.withCString(a1) { s1 in unsafe c(a0, s1) } }
        } else {
            tabPagePush = nil
        }
        browserSetPageDisplay = try r("cmux_shim_browser_set_page_display")
        unsafe initialize = try r("cmux_shim_initialize")
        doWork = try r("cmux_shim_do_work")
        setPumpTimeSlice = try r("cmux_shim_set_pump_time_slice")
        unsafe setScheduleDelayed = try r("cmux_shim_set_schedule_delayed")
        let cSetEnergySaver: @convention(c) (Int32, UnsafePointer<CChar>?) -> Int32 = try unsafe r("cmux_shim_set_energy_saver")
        setEnergySaver = { a0, a1 in unsafe Self.withCString(a1) { s1 in unsafe cSetEnergySaver(a0, s1) } }
        memoryPressureVote = try r("cmux_shim_memory_pressure_vote")
        let cCreateWindow: @convention(c) (Int32, UnsafeMutableRawPointer?, Int32, Int32, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Int32 =
            try unsafe r("cmux_shim_create_window")
        createWindow = { a0, parent, a2, a3, a4, a5 in
            unsafe Self.withCString(a4) { s4 in unsafe Self.withCString(a5) { s5 in unsafe cCreateWindow(a0, parent?.pointer, a2, a3, s4, s5) } }
        }
        let cCreatePlaceholderWindow: @convention(c) (Int32, UnsafeMutableRawPointer?, Int32, Int32, UnsafePointer<CChar>?) -> Int32 =
            try unsafe r("cmux_shim_create_placeholder_window")
        createPlaceholderWindow = { a0, parent, a2, a3, a4 in
            unsafe Self.withCString(a4) { s4 in unsafe cCreatePlaceholderWindow(a0, parent?.pointer, a2, a3, s4) }
        }
        placeholderSupported = try r("cmux_shim_placeholder_supported")
        let cTabAdd: @convention(c) (Int32, UnsafePointer<CChar>?, Int32, Int32) -> Int32 = try unsafe r("cmux_shim_tab_add")
        tabAdd = { a0, a1, a2, a3 in unsafe Self.withCString(a1) { s1 in unsafe cTabAdd(a0, s1, a2, a3) } }
        tabDuplicate = try r("cmux_shim_tab_duplicate")
        tabActivate = try r("cmux_shim_tab_activate")
        let cTabNavigationEntries: @convention(c) (Int32) -> UnsafeMutablePointer<CChar>? = try unsafe r("cmux_shim_tab_navigation_entries")
        tabNavigationEntries = { a0 in unsafe Self.take(cTabNavigationEntries(a0), cFree) }
        tabGoToEntry = try r("cmux_shim_tab_go_to_entry")
        tabWindowID = try r("cmux_shim_tab_window_id")
        let cLoadURL: @convention(c) (Int32, UnsafePointer<CChar>?) -> Void = try unsafe r("cmux_shim_load_url")
        loadURL = { a0, a1 in unsafe Self.withCString(a1) { s1 in unsafe cLoadURL(a0, s1) } }
        goBack = try r("cmux_shim_go_back")
        goForward = try r("cmux_shim_go_forward")
        reload = try r("cmux_shim_reload")
        stop = try r("cmux_shim_stop")
        setFocus = try r("cmux_shim_set_focus")
        setZoomLevel = try r("cmux_shim_set_zoom_level")
        setAccessibility = try r("cmux_shim_set_accessibility")
        printPage = try r("cmux_shim_print")
        let cFind: @convention(c) (Int32, Int32, UnsafePointer<CChar>?, Int32, Int32, Int32) -> Void = try unsafe r("cmux_shim_find")
        find = { a0, a1, a2, a3, a4, a5 in unsafe Self.withCString(a2) { s2 in unsafe cFind(a0, a1, s2, a3, a4, a5) } }
        stopFinding = try r("cmux_shim_stop_finding")
        close = try r("cmux_shim_close")
        tryClose = try r("cmux_shim_try_close")
        beforeUnloadReply = try r("cmux_shim_before_unload_reply")
        let cDevToolsCall: @convention(c) (Int32, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Int32 = try unsafe r("cmux_shim_devtools_call")
        devToolsCall = { a0, a1, a2 in unsafe Self.withCString(a1) { s1 in unsafe Self.withCString(a2) { s2 in unsafe cDevToolsCall(a0, s1, s2) } } }
        devToolsWatchEvents = try r("cmux_shim_devtools_watch_events")
        let cDevToolsSend: @convention(c) (Int32, UnsafePointer<CChar>?) -> Int32 = try unsafe r("cmux_shim_devtools_send")
        devToolsSend = { a0, a1 in unsafe Self.withCString(a1) { s1 in unsafe cDevToolsSend(a0, s1) } }
        unsafe devToolsSetKeyHandler = try r("cmux_shim_devtools_set_key_handler")
        unsafe setUnhandledKeyHandler = try r("cmux_shim_set_unhandled_key_handler")
        let cDevToolsSetPlacement: @convention(c) (Int32, UnsafeMutableRawPointer?, Int32, Int32, Int32, Int32) -> Void =
            try unsafe r("cmux_shim_devtools_set_placement")
        devToolsSetPlacement = { a0, parent, a2, a3, a4, a5 in unsafe cDevToolsSetPlacement(a0, parent?.pointer, a2, a3, a4, a5) }
        devToolsCommand = try r("cmux_shim_devtools_command")
        devToolsBrowser = try r("cmux_shim_devtools_browser")
        devToolsSetFocus = try r("cmux_shim_devtools_set_focus")
        let cDevToolsShowPanel: @convention(c) (Int32, UnsafePointer<CChar>?) -> Int32 = try unsafe r("cmux_shim_devtools_show_panel")
        devToolsShowPanel = { a0, a1 in unsafe Self.withCString(a1) { s1 in unsafe cDevToolsShowPanel(a0, s1) } }
        let cExtActions: @convention(c) (Int32, Int32) -> UnsafeMutablePointer<CChar>? = try unsafe r("cmux_shim_ext_actions")
        extActions = { a0, a1 in unsafe Self.take(cExtActions(a0, a1), cFree) }
        let cExtActionRun: @convention(c) (Int32, UnsafePointer<CChar>?, Int32, Int32) -> Int32 = try unsafe r("cmux_shim_ext_action_run")
        extActionRun = { a0, a1, a2, a3 in unsafe Self.withCString(a1) { s1 in unsafe cExtActionRun(a0, s1, a2, a3) } }
        let cExtActionHidePopup: @convention(c) (Int32, UnsafePointer<CChar>?) -> Void = try unsafe r("cmux_shim_ext_action_hide_popup")
        extActionHidePopup = { a0, a1 in unsafe Self.withCString(a1) { s1 in unsafe cExtActionHidePopup(a0, s1) } }
        let cExtActionContextMenu: @convention(c) (Int32, UnsafePointer<CChar>?, Int32, Int32) -> Void = try unsafe r("cmux_shim_ext_action_context_menu")
        extActionContextMenu = { a0, a1, a2, a3 in unsafe Self.withCString(a1) { s1 in unsafe cExtActionContextMenu(a0, s1, a2, a3) } }
        let cTabNavigationState: @convention(c) (Int32) -> UnsafeMutablePointer<CChar>? = try unsafe r("cmux_shim_tab_navigation_state")
        tabNavigationState = { a0 in unsafe Self.take(cTabNavigationState(a0), cFree) }
        let cTabRestoreNavigation: @convention(c) (Int32, UnsafePointer<CChar>?) -> Int32 = try unsafe r("cmux_shim_tab_restore_navigation")
        tabRestoreNavigation = { a0, a1 in unsafe Self.withCString(a1) { s1 in unsafe cTabRestoreNavigation(a0, s1) } }
        navigationRestoreSupported = try r("cmux_shim_navigation_restore_supported")
        let cExtList: @convention(c) (Int32) -> UnsafeMutablePointer<CChar>? = try unsafe r("cmux_shim_ext_list")
        extList = { a0 in unsafe Self.take(cExtList(a0), cFree) }
        let cExtSetEnabled: @convention(c) (Int32, UnsafePointer<CChar>?, Int32) -> Int32 = try unsafe r("cmux_shim_ext_set_enabled")
        extSetEnabled = { a0, a1, a2 in unsafe Self.withCString(a1) { s1 in unsafe cExtSetEnabled(a0, s1, a2) } }
        let cExtUninstall: @convention(c) (Int32, UnsafePointer<CChar>?) -> Int32 = try unsafe r("cmux_shim_ext_uninstall")
        extUninstall = { a0, a1 in unsafe Self.withCString(a1) { s1 in unsafe cExtUninstall(a0, s1) } }
        let cExtReload: @convention(c) (Int32, UnsafePointer<CChar>?) -> Int32 = try unsafe r("cmux_shim_ext_reload")
        extReload = { a0, a1 in unsafe Self.withCString(a1) { s1 in unsafe cExtReload(a0, s1) } }
        let cExtMovePinned: @convention(c) (Int32, UnsafePointer<CChar>?, Int32) -> Int32 = try unsafe r("cmux_shim_ext_move_pinned")
        extMovePinned = { a0, a1, a2 in unsafe Self.withCString(a1) { s1 in unsafe cExtMovePinned(a0, s1, a2) } }
        let cExtSetPinned: @convention(c) (Int32, UnsafePointer<CChar>?, Int32) -> Int32 = try unsafe r("cmux_shim_ext_set_pinned")
        extSetPinned = { a0, a1, a2 in unsafe Self.withCString(a1) { s1 in unsafe cExtSetPinned(a0, s1, a2) } }
        let cExtOpenOptions: @convention(c) (Int32, UnsafePointer<CChar>?) -> Int32 = try unsafe r("cmux_shim_ext_open_options")
        extOpenOptions = { a0, a1 in unsafe Self.withCString(a1) { s1 in unsafe cExtOpenOptions(a0, s1) } }
        let cExtLoadUnpacked: @convention(c) (Int32, UnsafePointer<CChar>?) -> Int32 = try unsafe r("cmux_shim_ext_load_unpacked")
        extLoadUnpacked = { a0, a1 in unsafe Self.withCString(a1) { s1 in unsafe cExtLoadUnpacked(a0, s1) } }
        extLoadLaterSupported = try r("cmux_shim_ext_load_later_supported")
        let cExtLoadCommandLine: @convention(c) (UnsafePointer<CChar>?, Int32, UnsafePointer<CChar>?) -> Int32 =
            try unsafe r("cmux_shim_ext_load_command_line")
        extLoadCommandLine = { a0, a1, a2 in unsafe Self.withCString(a0) { s0 in unsafe Self.withCString(a2) { s2 in unsafe cExtLoadCommandLine(s0, a1, s2) } } }
        let cExtCommands: @convention(c) (Int32) -> UnsafeMutablePointer<CChar>? = try unsafe r("cmux_shim_ext_commands")
        extCommands = { a0 in unsafe Self.take(cExtCommands(a0), cFree) }
        let cExtCommandRun: @convention(c) (Int32, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Int32 = try unsafe r("cmux_shim_ext_command_run")
        extCommandRun = { a0, a1, a2 in unsafe Self.withCString(a1) { s1 in unsafe Self.withCString(a2) { s2 in unsafe cExtCommandRun(a0, s1, s2) } } }
        tabMoveToWindow = try r("cmux_shim_tab_move_to_window")
        contextMenuDone = try r("cmux_shim_context_menu_done")
        unresponsiveReply = try r("cmux_shim_unresponsive_reply")
        closeAll = try r("cmux_shim_close_all")
        liveBrowserCount = try r("cmux_shim_live_browser_count")
        windowCount = try r("cmux_shim_window_count")
        shutdown = try r("cmux_shim_shutdown")
        unsafe setWindowRequestHandler = try r("cmux_shim_set_window_request_handler")
        unsafe setWindowRequestPolicy = try r("cmux_shim_set_window_request_policy")
        unsafe setFocusRequestHandler = try r("cmux_shim_set_focus_request_handler")
        foreignBrowserCount = try r("cmux_shim_foreign_browser_count")
        let cDownloadURL: @convention(c) (Int32, UnsafePointer<CChar>?) -> Int32 = try unsafe r("cmux_shim_download_url")
        downloadURL = { a0, a1 in unsafe Self.withCString(a1) { s1 in unsafe cDownloadURL(a0, s1) } }
        let cDownloadContinue: @convention(c) (Int32, UnsafePointer<CChar>?) -> Int32 = try unsafe r("cmux_shim_download_continue")
        downloadContinue = { a0, a1 in unsafe Self.withCString(a1) { s1 in unsafe cDownloadContinue(a0, s1) } }
        downloadControl = try r("cmux_shim_download_control")
        permissionContinue = try r("cmux_shim_permission_continue")
        let cContentSetting: @convention(c) (Int32, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Int32 = try unsafe r("cmux_shim_content_setting")
        contentSetting = { a0, a1, a2 in unsafe Self.withCString(a1) { s1 in unsafe Self.withCString(a2) { s2 in unsafe cContentSetting(a0, s1, s2) } } }
        let cSetContentSetting: @convention(c) (Int32, UnsafePointer<CChar>?, UnsafePointer<CChar>?, Int32) -> Int32 = try unsafe r("cmux_shim_set_content_setting")
        setContentSetting = { a0, a1, a2, a3 in unsafe Self.withCString(a1) { s1 in unsafe Self.withCString(a2) { s2 in unsafe cSetContentSetting(a0, s1, s2, a3) } } }
        visitCookies = try r("cmux_shim_visit_cookies")
        let cDeleteCookies: @convention(c) (Int32, Int32, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Int32 = try unsafe r("cmux_shim_delete_cookies")
        deleteCookies = { a0, a1, a2, a3 in unsafe Self.withCString(a2) { s2 in unsafe Self.withCString(a3) { s3 in unsafe cDeleteCookies(a0, a1, s2, s3) } } }
        let cDownloadFavicon: @convention(c) (Int32, Int32, UnsafePointer<CChar>?, Int32) -> Int32 = try unsafe r("cmux_shim_download_favicon")
        downloadFavicon = { a0, a1, a2, a3 in unsafe Self.withCString(a2) { s2 in unsafe cDownloadFavicon(a0, a1, s2, a3) } }
        let cImportCookies: @convention(c) (UnsafePointer<CChar>?, Int32, UnsafePointer<CChar>?) -> Int32 = try unsafe r("cmux_shim_import_cookies")
        importCookies = { a0, a1, a2 in unsafe Self.withCString(a0) { s0 in unsafe Self.withCString(a2) { s2 in unsafe cImportCookies(s0, a1, s2) } } }
        let cClearCookies: @convention(c) (UnsafePointer<CChar>?, Int32, Int64) -> Int32 = try unsafe r("cmux_shim_clear_cookies")
        clearCookies = { a0, a1, a2 in unsafe Self.withCString(a0) { s0 in unsafe cClearCookies(s0, a1, a2) } }
        let cImportPasswords: @convention(c) (UnsafePointer<CChar>?, Int32, UnsafeRawPointer?, Int32) -> Int32 =
            try unsafe r("cmux_shim_import_passwords")
        // SAFETY: `rows` holds `count` rows of `cmux_shim_password_entry` (ChromiumPasswordRows.stride bytes each,
        // checked against `passwordEntrySize`), alive while the caller holds it; the shim copies them before it returns.
        importPasswords = { a0, a1, rows in unsafe Self.withCString(a0) { s0 in unsafe cImportPasswords(s0, a1, rows.rows, Int32(rows.count)) } }
        passwordEntrySize = try r("cmux_shim_password_entry_size")
        passwordImportAvailable = try r("cmux_shim_password_import_available")
        let cReplacePasswords: @convention(c) (UnsafePointer<CChar>?, Int32, UnsafeRawPointer?, Int32) -> Int32 =
            try unsafe r("cmux_shim_replace_passwords")
        // SAFETY: as for importPasswords.
        replacePasswords = { a0, a1, rows in unsafe Self.withCString(a0) { s0 in unsafe cReplacePasswords(s0, a1, rows.rows, Int32(rows.count)) } }
        passwordReplaceAvailable = try r("cmux_shim_password_replace_available")
        let cPasswordPromptAnswer: @convention(c) (Int32, Int32, UnsafePointer<CChar>?) -> Int32 = try unsafe r("cmux_shim_password_prompt_answer")
        passwordPromptAnswer = { a0, a1, a2 in unsafe Self.withCString(a2) { s2 in unsafe cPasswordPromptAnswer(a0, a1, s2) } }
        setPasswordGenerationEnabled = try r("cmux_shim_set_password_generation_enabled")
        setPasswordFill = try r("cmux_shim_set_password_fill")
        passkeysAvailable = try r("cmux_shim_passkeys_available")
        let cPasskeysList: @convention(c) (UnsafePointer<CChar>?, Int32) -> Int32 = try unsafe r("cmux_shim_passkeys_list")
        passkeysList = { a0, a1 in unsafe Self.withCString(a0) { s0 in unsafe cPasskeysList(s0, a1) } }
        let cPasskeyDelete: @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?, Int32) -> Int32 = try unsafe r("cmux_shim_passkey_delete")
        passkeyDelete = { a0, a1, a2 in unsafe Self.withCString(a0) { s0 in unsafe Self.withCString(a1) { s1 in unsafe cPasskeyDelete(s0, s1, a2) } } }
        passwordCoreAvailable = try r("cmux_shim_password_core_available")
        let cPasswordList: @convention(c) (UnsafePointer<CChar>?, Int32) -> Int32 = try unsafe r("cmux_shim_password_list")
        passwordList = { a0, a1 in unsafe Self.withCString(a0) { s0 in unsafe cPasswordList(s0, a1) } }
        let cPasswordRemove: @convention(c) (UnsafePointer<CChar>?, UnsafePointer<UnsafePointer<CChar>?>?, Int32, Int32) -> Int32 =
            try unsafe r("cmux_shim_password_remove")
        passwordRemove = { a0, ids, a2 in
            // SAFETY: strdup makes a NUL-terminated copy of each id (NULL when out of memory, which the
            // shim skips); the copies outlive the call and are freed once, after it, by the defer.
            let copies: [UnsafeMutablePointer<CChar>?] = unsafe ids.map { unsafe strdup($0) }
            defer { unsafe copies.forEach { unsafe Darwin.free($0) } }
            let pointers: [UnsafePointer<CChar>?] = unsafe copies.map { unsafe UnsafePointer($0) }
            // SAFETY: `pointers` is an array of ids.count live C strings (above) for the call alone.
            return unsafe Self.withCString(a0) { s0 in unsafe cPasswordRemove(s0, pointers, Int32(pointers.count), a2) }
        }
        let cPasswordExceptionRemove: @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?, Int32) -> Int32 = try unsafe r("cmux_shim_password_exception_remove")
        passwordExceptionRemove = { a0, a1, a2 in unsafe Self.withCString(a0) { s0 in unsafe Self.withCString(a1) { s1 in unsafe cPasswordExceptionRemove(s0, s1, a2) } } }
        let cPasswordSetUsername: @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?, UnsafePointer<CChar>?, Int32) -> Int32 = try unsafe r("cmux_shim_password_set_username")
        passwordSetUsername = { a0, a1, a2, a3 in unsafe Self.withCString(a0) { s0 in unsafe Self.withCString(a1) { s1 in unsafe Self.withCString(a2) { s2 in unsafe cPasswordSetUsername(s0, s1, s2, a3) } } } }
        let cPasswordReveal: @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?, PasswordRevealCallback?, UnsafeMutableRawPointer?) -> Int32 =
            try unsafe r("cmux_shim_password_reveal")
        unsafe passwordReveal = { a0, a1, callback, context in
            unsafe Self.withCString(a0) { s0 in unsafe Self.withCString(a1) { s1 in unsafe cPasswordReveal(s0, s1, callback, context) } }
        }
        let cPasswordExport: @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?, Int32) -> Int32 = try unsafe r("cmux_shim_password_export")
        passwordExport = { a0, a1, a2 in unsafe Self.withCString(a0) { s0 in unsafe Self.withCString(a1) { s1 in unsafe cPasswordExport(s0, s1, a2) } } }
        let cSslStatus: @convention(c) (Int32) -> UnsafeMutablePointer<CChar>? = try unsafe r("cmux_shim_ssl_status")
        sslStatus = { a0 in unsafe Self.take(cSslStatus(a0), cFreeOwned) }
        clearCertificateExceptions = try r("cmux_shim_clear_certificate_exceptions")
        let cCertificateProceed: @convention(c) (Int32, UnsafePointer<CChar>?, Int32, Int32) -> Int32 = try unsafe r("cmux_shim_certificate_proceed")
        certificateProceed = { a0, a1, a2, a3 in unsafe Self.withCString(a1) { s1 in unsafe cCertificateProceed(a0, s1, a2, a3) } }
        let cRendererClientIDs: @convention(c) (Int32, UnsafeMutablePointer<Int32>?, Int32) -> Int32 = try unsafe r("cmux_shim_renderer_client_ids")
        rendererClientIDs = { browser, capacity in
            var ids = [Int32](repeating: 0, count: max(Int(capacity), 0))
            let room = Int32(ids.count)
            // SAFETY: the shim writes at most `room` ids into the array's buffer during the call.
            let count = unsafe cRendererClientIDs(browser, &ids, room)
            return Array(ids.prefix(Int(min(max(count, 0), room))))
        }
        let cRendererFrames: @convention(c) (UnsafeMutablePointer<Int32>?, UnsafeMutablePointer<Int32>?, UnsafeMutablePointer<Int32>?, Int32) -> Int32 =
            try unsafe r("cmux_shim_renderer_frames")
        rendererFrames = {
            // A second call sized to the first one's count; the browsers cannot change between them on this thread.
            var room = 64
            for _ in 0 ..< 2 {
                var browsers = [Int32](repeating: 0, count: room), ids = browsers, frames = browsers
                // SAFETY: the shim writes at most `room` entries into each array's buffer during the call.
                let count = Int(max(unsafe cRendererFrames(&browsers, &ids, &frames, Int32(room)), 0))
                guard count > room else {
                    return (0 ..< count).map { CEFRendererFrames.Entry(browser: browsers[$0], clientID: ids[$0], frames: Int(frames[$0])) }
                }
                room = count
            }
            return nil
        }
        rendererPID = try r("cmux_shim_renderer_pid")
        let cAddDocumentScript: (@convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?, Int32, Int32) -> Int32)? = unsafe r.optional("cmux_shim_add_document_script")
        if let c = unsafe cAddDocumentScript {
            addDocumentScript = { a0, a1, a2, a3 in unsafe Self.withCString(a0) { s0 in unsafe Self.withCString(a1) { s1 in unsafe c(s0, s1, a2, a3) } } }
        } else {
            addDocumentScript = nil
        }
        let cAddPageChannel: (@convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Int32)? = unsafe r.optional("cmux_shim_add_page_channel")
        if let c = unsafe cAddPageChannel {
            addPageChannel = { a0, a1 in unsafe Self.withCString(a0) { s0 in unsafe Self.withCString(a1) { s1 in unsafe c(s0, s1) } } }
        } else {
            addPageChannel = nil
        }
        let cTabEvaluate: (@convention(c) (Int32, Int32, UnsafePointer<CChar>?, UnsafePointer<CChar>?, Int32) -> Int32)? = unsafe r.optional("cmux_shim_tab_evaluate")
        if let c = unsafe cTabEvaluate {
            tabEvaluate = { a0, a1, a2, a3, a4 in unsafe Self.withCString(a2) { s2 in unsafe Self.withCString(a3) { s3 in unsafe c(a0, a1, s2, s3, a4) } } }
        } else {
            tabEvaluate = nil
        }
        tabSetFrozen = r.optional("cmux_shim_tab_set_frozen")
        tabSendClick = r.optional("cmux_shim_tab_send_click")
        tabSendMouseMove = r.optional("cmux_shim_tab_send_mouse_move")
        tabSetColorScheme = r.optional("cmux_shim_tab_set_color_scheme")
        tabDiscard = r.hostExports == nil ? r.optional("cmux_shim_tab_discard") : nil
        tabCopySurface = r.optional("cmux_shim_tab_copy_surface")
        widgets = CEFShimWidgetOps(setGeometry: r.optional("cmux_shim_widget_set_geometry"), dismiss: r.optional("cmux_shim_widget_dismiss"),
                                   sendInput: r.optional("cmux_shim_widget_send_input"))
        dragTarget = try CEFShimDragTargetOps(r)
        locks = try CEFShimLockOps(r)
        popupMenus = try CEFShimPopupMenuOps(r)
        suggestions = try CEFShimSuggestionOps(r)
        choosers = try CEFShimChooserOps(r)
        let cImeSetComposition: (@convention(c) (Int32, UnsafePointer<UInt8>?, Int32, UnsafePointer<UInt8>?, Int32, Int32, Int32, Int32,
                                                 Int32) -> Void)? = unsafe r.optional("cmux_shim_browser_ime_set_composition")
        let cImeCommitText: (@convention(c) (Int32, UnsafePointer<UInt8>?, Int32, Int32, Int32) -> Void)? = unsafe r.optional("cmux_shim_browser_ime_commit_text")
        var imeSetComposition: ((Int32, [UInt8], [UInt8], Int32, Int32, Int32, Int32) -> Void)?
        if let c = unsafe cImeSetComposition {
            imeSetComposition = { browser, text, clauses, selectionStart, selectionEnd, replaceStart, replaceEnd in
                unsafe c(browser, text, Int32(clamping: text.count), clauses, Int32(clamping: clauses.count), selectionStart, selectionEnd,
                         replaceStart, replaceEnd)
            }
        }
        var imeCommitText: ((Int32, [UInt8], Int32, Int32) -> Void)?
        if let c = unsafe cImeCommitText {
            imeCommitText = { browser, text, replaceStart, replaceEnd in unsafe c(browser, text, Int32(clamping: text.count), replaceStart, replaceEnd) }
        }
        textInput = CEFShimTextInputOps(setComposition: imeSetComposition, commitText: imeCommitText,
                                        finishComposing: r.optional("cmux_shim_browser_ime_finish_composing"),
                                        cancelComposition: r.optional("cmux_shim_browser_ime_cancel_composition"))
        let cBrowserAttachView: (@convention(c) (Int32, UnsafeMutableRawPointer?) -> Int32)? = unsafe r.optional("cmux_shim_browser_attach_view")
        if r.hostExports == nil, let c = unsafe cBrowserAttachView {  // host mode: no view pointer crosses the process
            browserAttachView = { browser, parent in unsafe c(browser, parent?.pointer) }
        } else {
            browserAttachView = nil
        }
        let cSetContextProxy: @convention(c) (UnsafePointer<CChar>?, Int32) -> Int32 = try unsafe r("cmux_shim_set_context_proxy")
        setContextProxy = { a0, a1 in unsafe Self.withCString(a0) { s0 in unsafe cSetContextProxy(s0, a1) } }
        let cContextProxyState: @convention(c) (UnsafePointer<CChar>?) -> Int32 = try unsafe r("cmux_shim_context_proxy_state")
        contextProxyState = { a0 in unsafe Self.withCString(a0) { s0 in unsafe cContextProxyState(s0) } }
        let cSetContextProxyServer: @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Int32 = try unsafe r("cmux_shim_set_context_proxy_server")
        setContextProxyServer = { a0, a1, a2 in unsafe Self.withCString(a0) { s0 in unsafe Self.withCString(a1) { s1 in unsafe Self.withCString(a2) { s2 in unsafe cSetContextProxyServer(s0, s1, s2) } } } }
        let cReleaseContext: @convention(c) (UnsafePointer<CChar>?) -> Void = try unsafe r("cmux_shim_release_context")
        releaseContext = { a0 in unsafe Self.withCString(a0) { s0 in unsafe cReleaseContext(s0) } }
        setNavigationGuard = try r("cmux_shim_set_navigation_guard")
        let cSetAuthCallback: @convention(c) (Int32, UnsafePointer<CChar>?, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Void = try unsafe r("cmux_shim_set_auth_callback")
        setAuthCallback = { a0, a1, a2, a3 in unsafe Self.withCString(a1) { s1 in unsafe Self.withCString(a2) { s2 in unsafe Self.withCString(a3) { s3 in unsafe cSetAuthCallback(a0, s1, s2, s3) } } } }
        let cPrefGet: @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>? = try unsafe r("cmux_shim_pref_get")
        prefGet = { a0, a1 in unsafe Self.withCString(a0) { s0 in unsafe Self.withCString(a1) { s1 in unsafe Self.take(cPrefGet(s0, s1), cFreeOwned) } } }
        let cPrefSetBool: @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?, Int32) -> Int32 = try unsafe r("cmux_shim_pref_set_bool")
        prefSetBool = { a0, a1, a2 in unsafe Self.withCString(a0) { s0 in unsafe Self.withCString(a1) { s1 in unsafe cPrefSetBool(s0, s1, a2) } } }
        let cPrefWatch: @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?, Int32) -> Int32 = try unsafe r("cmux_shim_pref_watch")
        prefWatch = { a0, a1, a2 in unsafe Self.withCString(a0) { s0 in unsafe Self.withCString(a1) { s1 in unsafe cPrefWatch(s0, s1, a2) } } }
        let cBookmarksSync: @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Int32 = try unsafe r("cmux_shim_bookmarks_sync")
        bookmarksSync = { a0, a1 in unsafe Self.withCString(a0) { s0 in unsafe Self.withCString(a1) { s1 in unsafe cBookmarksSync(s0, s1) } } }
        let cPageSchemeAdd: @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Int32 = try unsafe r("cmux_shim_page_scheme_add")
        pageSchemeAdd = { a0, a1, a2 in unsafe Self.withCString(a0) { s0 in unsafe Self.withCString(a1) { s1 in unsafe Self.withCString(a2) { s2 in unsafe cPageSchemeAdd(s0, s1, s2) } } } }
        let cPageSchemeAddFirstParty: @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Int32 = try unsafe r("cmux_shim_page_scheme_add_first_party")
        pageSchemeAddFirstParty = { a0, a1, a2 in unsafe Self.withCString(a0) { s0 in unsafe Self.withCString(a1) { s1 in unsafe Self.withCString(a2) { s2 in unsafe cPageSchemeAddFirstParty(s0, s1, s2) } } } }
        let cPageSchemeAddFirstPartyDynamic: @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?, UnsafePointer<CChar>?, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Int32 = try unsafe r("cmux_shim_page_scheme_add_first_party_dynamic")
        pageSchemeAddFirstPartyDynamic = { a0, a1, a2, a3, a4 in unsafe Self.withCString(a0) { s0 in unsafe Self.withCString(a1) { s1 in unsafe Self.withCString(a2) { s2 in unsafe Self.withCString(a3) { s3 in unsafe Self.withCString(a4) { s4 in unsafe cPageSchemeAddFirstPartyDynamic(s0, s1, s2, s3, s4) } } } } } }
        let cPageSchemeSetGroup: (@convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Int32)? = unsafe r.optional("cmux_shim_page_scheme_set_group")
        if let c = unsafe cPageSchemeSetGroup {
            pageSchemeSetGroup = { a0, a1 in unsafe Self.withCString(a0) { s0 in unsafe Self.withCString(a1) { s1 in unsafe c(s0, s1) } } }
        } else {
            pageSchemeSetGroup = nil
        }
        let cPageResourceRespond: @convention(c) (Int32, Int32, UnsafePointer<CChar>?, UnsafeRawPointer?, Int) -> Int32 =
            try unsafe r("cmux_shim_page_resource_respond")
        pageResourceRespond = { a0, a1, a2, body in
            let bytes = [UInt8](body)
            // SAFETY: the array's buffer holds bytes.count bytes for the call; the shim copies the body before it returns.
            return unsafe Self.withCString(a2) { s2 in unsafe cPageResourceRespond(a0, a1, s2, bytes, bytes.count) }
        }
        let cSetNewTabPageURL: @convention(c) (UnsafePointer<CChar>?) -> Void = try unsafe r("cmux_shim_set_new_tab_page_url")
        setNewTabPageURL = { a0 in unsafe Self.withCString(a0) { s0 in unsafe cSetNewTabPageURL(s0) } }
        let cAddNativeMessagingDir: @convention(c) (UnsafePointer<CChar>?, Int32) -> Int32 = try unsafe r("cmux_shim_add_native_messaging_dir")
        addNativeMessagingDir = { a0, a1 in unsafe Self.withCString(a0) { s0 in unsafe cAddNativeMessagingDir(s0, a1) } }
        installPromptReply = try r("cmux_shim_install_prompt_reply")
        let cOmniboxKeywords: @convention(c) (Int32) -> UnsafeMutablePointer<CChar>? = try unsafe r("cmux_shim_omnibox_keywords")
        omniboxKeywords = { a0 in unsafe Self.take(cOmniboxKeywords(a0), cFree) }
        let cOmniboxInput: @convention(c) (Int32, UnsafePointer<CChar>?, Int32, UnsafePointer<CChar>?, Int32) -> Int32 = try unsafe r("cmux_shim_omnibox_input")
        omniboxInput = { a0, a1, a2, a3, a4 in unsafe Self.withCString(a1) { s1 in unsafe Self.withCString(a3) { s3 in unsafe cOmniboxInput(a0, s1, a2, s3, a4) } } }
        setPopupWindowsEnabled = try r("cmux_shim_set_popup_windows_enabled")
        let cPopupWindowBounds: BoundsFn = try unsafe r("cmux_shim_popup_window_bounds")
        popupWindowBounds = { unsafe Self.bounds(cPopupWindowBounds, $0) }
        let cPopupWindowAttach: ParentViewFn = try unsafe r("cmux_shim_popup_window_attach")
        popupWindowAttach = { a0, parent, a2, a3 in unsafe cPopupWindowAttach(a0, parent?.pointer, a2, a3) }
        let cDevToolsInspectedBounds: BoundsFn = try unsafe r("cmux_shim_devtools_inspected_bounds")
        devToolsInspectedBounds = { unsafe Self.bounds(cDevToolsInspectedBounds, $0) }
        let cSidePanelState: @convention(c) (Int32) -> UnsafeMutablePointer<CChar>? = try unsafe r("cmux_shim_side_panel_state")
        sidePanelState = { a0 in unsafe Self.take(cSidePanelState(a0), cFree) }
        let cSidePanelPress: @convention(c) (Int32, UnsafePointer<CChar>?) -> Int32 = try unsafe r("cmux_shim_side_panel_press")
        sidePanelPress = { a0, a1 in unsafe Self.withCString(a1) { s1 in unsafe cSidePanelPress(a0, s1) } }
    }

    /// `text` as the NUL-terminated C string `body` reads during its call; NULL for nil (the ABI's "none").
    private static func withCString<Result>(_ text: String?, _ body: (UnsafePointer<CChar>?) -> Result) -> Result {
        guard let text else { return unsafe body(nil) }
        return unsafe text.withCString { unsafe body($0) }
    }

    /// A string the shim allocated, copied into Swift and released with `free`; nil for NULL.
    private static func take(_ pointer: UnsafeMutablePointer<CChar>?, _ free: FreeFn) -> String? {
        guard let pointer = unsafe pointer else { return nil }
        defer { unsafe free(pointer) }
        return unsafe String(cString: pointer)
    }

    /// An out-parameter read: its four ints, which `read` writes during the call, and its result.
    private static func bounds(_ read: BoundsFn, _ id: Int32) -> CEFShimBounds {
        var x: Int32 = 0, y: Int32 = 0, width: Int32 = 0, height: Int32 = 0
        let result = unsafe read(id, &x, &y, &width, &height)
        return CEFShimBounds(result: result, x: x, y: y, width: width, height: height)
    }
}
