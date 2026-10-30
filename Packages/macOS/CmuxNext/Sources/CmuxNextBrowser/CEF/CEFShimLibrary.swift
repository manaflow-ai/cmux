import Darwin
import Foundation

/// The C ABI of `libcmux_cef_shim.dylib`, resolved with `dlsym`; in host mode
/// the same ABI of the remote shim (``CEFRemoteShim``), checked the same way.
///
/// Mirrors `Sources/CmuxNextBrowser/CEF/Shim/cmux_cef_shim.h`; the shim must
/// have the same ABI identity (`CEFShimABI`). The shim
/// is loaded only when the first CEF tab is created, so a session without CEF
/// tabs never maps the shim or the 367 MiB Chromium framework, and SwiftPM
/// builds need no CEF headers.
/// Immutable C function pointers, closures over them, and the immutable resolver they came from
/// (`dlsym` on a handle never closed): safe to hand from the loading thread to the main thread.
///
/// Memory safety: every C string, buffer and out-parameter crosses here, as
/// Chromium keeps its `UNSAFE_BUFFERS()` at the boundary (docs/unsafe_buffers.md). Callers pass and
/// get Swift values (`String?`, `[Int32]`, ``CEFShimBounds``, ``CEFParentView``); only the
/// callback installers, `initialize`, `passwordReveal`'s callback and context, and the mirror's `free` keep C types.
@safe
nonisolated struct CEFShimLibrary: @unchecked Sendable {
    typealias FreeFn = @convention(c) (UnsafeMutablePointer<CChar>?) -> Void
    typealias BoundsFn = @convention(c) (Int32, UnsafeMutablePointer<Int32>?, UnsafeMutablePointer<Int32>?,
                                         UnsafeMutablePointer<Int32>?, UnsafeMutablePointer<Int32>?) -> Int32
    typealias ParentViewFn = @convention(c) (Int32, UnsafeMutableRawPointer?, Int32, Int32) -> Int32
    typealias ScheduleFn = @convention(c) (UnsafeMutableRawPointer?, Int64) -> Void
    /// `cmux_shim_schedule_delayed_fn`: ctx, run time (uptime ns, `Int64.max` for none), leeway ns,
    /// precise (1 when it has no leeway).
    typealias ScheduleDelayedFn = @convention(c) (UnsafeMutableRawPointer?, Int64, Int64, Int32) -> Void
    typealias EventFn = @convention(c) (
        UnsafeMutableRawPointer?, Int32, Int32, Int32, Int64, Int64,
        UnsafePointer<CChar>?, UnsafePointer<CChar>?
    ) -> Void
    typealias KeyFn = @convention(c) (UnsafeMutableRawPointer?, Int32, UnsafeMutableRawPointer?) -> Int32
    /// `cmux_shim_window_request_fn`: ctx, kind, disposition, source,
    /// has_bounds, x, y, width, height, user gesture, url, profile path ->
    /// anchor browser.
    typealias WindowRequestFn = @convention(c) (
        UnsafeMutableRawPointer?, Int32, Int32, Int32, Int32, Int32, Int32, Int32, Int32, Int32,
        UnsafePointer<CChar>?, UnsafePointer<CChar>?
    ) -> Int32
    /// `cmux_shim_focus_request_fn`: ctx, browser, source -> 1 allow.
    typealias FocusRequestFn = @convention(c) (UnsafeMutableRawPointer?, Int32, Int32) -> Int32

    /// The shim's ABI identity (`cmux_shim_abi_id`, a static string), checked when it opens.
    let abiID: () -> String?
    /// `cmux_shim_load`: maps the framework at the path; nil when it loaded, else the shim's message.
    let loadFramework: (_ frameworkPath: String) -> String?
    let forkAPIVersion: @convention(c) () -> Int32
    let prepareApplication: @convention(c) () -> Int32
    let setExtensionDeveloperMode: @convention(c) (Int32) -> Void
    /// Chromium's default search provider in every profile (`CEFDefaultSearch`).
    let setDefaultSearch: (String?) -> Void
    /// The managed preference domain Chromium reads Chrome policies from (`CEFRuntime.chromePolicyIDSetting`).
    let setChromePolicyID: (String?) -> Void
    let setBackgroundColor: @convention(c) (UInt32) -> Void
    let browserSetBackgroundColor: @convention(c) (Int32, UInt32) -> Int32
    /// A see-through page (fork API 17, `CEFTab.pageSeeThrough`); 0 when the fork lacks it.
    let tabSetTransparentBackground: @convention(c) (Int32, Int32) -> Int32
    /// `cmux_shim_set_file_dialogs`: 1 sends page file choosers to the host (`CMUX_SHIM_FILE_DIALOG`).
    let setFileDialogs: @convention(c) (Int32) -> Void
    /// `cmux_shim_file_dialog_answer(dialog, multiple, paths)`: newline-separated absolute paths; nil or "" cancels.
    let fileDialogAnswer: (Int32, Int32, String?) -> Int32
    /// Fork API 26: `cmux_shim_browser_set_layer_hosting` (the page's CAContextID, 0 when off).
    let browserSetLayerHosting: @convention(c) (Int32, Int32) -> UInt32
    /// Fork API 27: `cmux_shim_browser_set_resize_sync` (deadline in ms, 0 never holds the commit).
    let browserSetResizeSync: @convention(c) (Int32, Int32) -> Int32
    /// `cmux_shim_browser_set_resize_fence(browser, fence, deadline_frames)` (fork API
    /// ``CEFLayerHosting/resizeFenceForkAPI``): 1 when the fork took its own send
    /// right to `fence` for the page's next GPU commit at its new size. Nil when the shim lacks the
    /// export, and in host mode: a Mach port name means nothing in the Chromium Host's process.
    let browserSetResizeFence: (@convention(c) (Int32, UInt32, UInt32) -> Int32)?
    /// Fork API 30: `cmux_shim_browser_set_embedder_active`, a detached page's key state: its focus
    /// with no key window (0 when the fork lacks it or the page is not detached).
    let browserSetEmbedderActive: @convention(c) (Int32, Int32) -> Int32
    /// Fork API 30: `cmux_shim_browser_accessibility_token(browser, embedder_pid, parent_token, parent_length,
    /// window_token, window_length, out, capacity)`: sets the page's accessibility parent and window from
    /// the embedder's tokens and returns the length of the page's own token, copied into `out` when it
    /// fits (0: none). Host mode answers in a REPLY (task 049, ``ChromiumHostAccessibilityToken``).
    let browserAccessibilityToken: (_ browser: Int32, _ embedderPID: Int32, _ viewToken: [UInt8], _ windowToken: [UInt8],
                                    _ capacity: Int32) -> ChromiumHostAccessibilityToken
    /// Fork API 34: `cmux_shim_browser_set_embedder_visibility` (a `cmux_shim_embedder_visibility_t`; 1 when the
    /// fork took it). Nil on a shim without the export.
    let browserSetEmbedderVisibility: (@convention(c) (Int32, Int32) -> Int32)?
    /// Fork API 31: `cmux_shim_browser_set_page_visibility` (a ``ChromiumHostPageVisibility``), what cmux shows
    /// of a detached page's window; host mode only.
    let browserSetPageVisibility: @convention(c) (Int32, Int32) -> Int32
    /// Fork API 37: `cmux_shim_tab_set_visibility(browser, visibility, capture)` (a `cmux_shim_tab_visibility_t`
    /// and a `cmux_shim_tab_capture_t`): the tab's visibility tree node caps its WebContents' visibility
    /// (``CEFTab/followVisibility(of:capture:)``). A post in host mode, so no caller reads its answer. Nil on a
    /// shim without the export.
    let tabSetVisibility: (@convention(c) (Int32, Int32, Int32) -> Int32)?
    /// Fork API 43: `cmux_shim_tab_page_push(browser, text)`, a string to the receiver a cmux-page document
    /// registered (the page push channel, ``CEFPagePush``). A post in host mode, so no caller reads its
    /// answer. Nil on a shim without the export.
    let tabPagePush: ((Int32, String) -> Int32)?
    /// Fork API 31: `cmux_shim_browser_set_page_display(browser, display_id, screen_x, screen_y)`, the display a
    /// detached page window takes its scale, color space and refresh rate from (task 221); 0 when the fork lacks it.
    let browserSetPageDisplay: @convention(c) (Int32, UInt32, Double, Double) -> Int32
    let initialize: @convention(c) (
        UnsafePointer<CChar>?, UnsafePointer<CChar>?, UnsafePointer<CChar>?, UnsafePointer<CChar>?,
        UnsafePointer<CChar>?, Int32, UnsafePointer<CChar>?, UnsafePointer<CChar>?,
        UnsafePointer<UnsafePointer<CChar>?>?,
        UnsafeMutableRawPointer?, ScheduleFn?, EventFn?, KeyFn?
    ) -> Int32
    let doWork: @convention(c) () -> Void
    /// `cmux_shim_set_pump_time_slice(us)`: the slice of the next `doWork` only (fork
    /// `cmux_set_message_loop_time_slice`); 1 when the fork has the call, 0 otherwise.
    let setPumpTimeSlice: @convention(c) (Int64) -> Int32
    /// `cmux_shim_set_schedule_delayed`: CEF's delayed work as absolute run times with Chromium's
    /// leeway; 1 when the fork has the call, 0 when delayed work stays on `ScheduleFn`.
    let setScheduleDelayed: @convention(c) (ScheduleDelayedFn?) -> Int32
    /// `cmux_shim_set_energy_saver(enabled, exempt_scheme)` (``CEFEnergySaver``); 1 when the fork took it.
    let setEnergySaver: (Int32, String?) -> Int32
    /// `cmux_shim_memory_pressure_vote(level)`: cmux's vote in Chromium's pressure aggregator (``CEFMemoryPressureVote``).
    let memoryPressureVote: @convention(c) (Int32) -> Int32
    /// `cmux_shim_tab_flush_back_forward_cache(browser)`: the tab's `BackForwardCache::Flush` (p07-memory-101); 0 on a
    /// fork without the call. A post to the Chromium Host, so callers discard the result (``CEFTab/flushBackForwardCache()``).
    let tabFlushBackForwardCache: @convention(c) (Int32) -> Int32

    let createWindow: (Int32, CEFParentView?, Int32, Int32, String?, String?) -> Int32
    /// The same window whose first tab has no renderer and never navigates (the spare window's
    /// placeholder, fork `CMUX_EXTRA_INFO_NO_RENDERER`); 0 when `placeholderSupported` is 0.
    let createPlaceholderWindow: (Int32, CEFParentView?, Int32, Int32, String?) -> Int32
    /// 1 when the fork makes renderer-less placeholders (`cmux_tab_renderer_state`).
    let placeholderSupported: @convention(c) () -> Int32
    let tabAdd: (Int32, String?, Int32, Int32) -> Int32
    let tabDuplicate: @convention(c) (Int32, Int32, Int32) -> Int32
    let tabActivate: @convention(c) (Int32) -> Int32
    let tabNavigationEntries: (Int32) -> String?
    let tabGoToEntry: @convention(c) (Int32, Int32) -> Int32
    let tabWindowID: @convention(c) (Int32) -> Int32

    let loadURL: (Int32, String?) -> Void
    let goBack: @convention(c) (Int32) -> Void
    let goForward: @convention(c) (Int32) -> Void
    let reload: @convention(c) (Int32) -> Void
    let stop: @convention(c) (Int32) -> Void
    let setFocus: @convention(c) (Int32, Int32) -> Void
    let setZoomLevel: @convention(c) (Int32, Double) -> Void
    /// Chromium's page accessibility on (1) or off (0) (`CEFAccessibility`).
    let setAccessibility: @convention(c) (Int32, Int32) -> Void
    /// Chromium's print preview over the page; 0 when the browser is gone.
    let printPage: @convention(c) (Int32) -> Int32
    let find: (Int32, Int32, String?, Int32, Int32, Int32) -> Void
    let stopFinding: @convention(c) (Int32, Int32) -> Void
    let close: @convention(c) (Int32) -> Void
    /// A person's close: 1 closes now, 0 runs beforeunload first (`CEFTab+UserClose`).
    let tryClose: @convention(c) (Int32) -> Int32
    /// Answers BEFORE_UNLOAD_DIALOG (token, 1 = Leave).
    let beforeUnloadReply: @convention(c) (Int32, Int32) -> Int32
    let devToolsCall: (Int32, String?, String?) -> Int32
    /// Raw DevTools protocol (`CEFDevToolsRawMessage`): watch a browser's
    /// events, send a message with an id from 2^30 (1 sent, 0 gone, -1 refused).
    let devToolsWatchEvents: @convention(c) (Int32, Int32) -> Void
    let devToolsSend: (Int32, String?) -> Int32

    /// `cmux_shim_devtools_command_t`.
    enum DevToolsCommand {
        static let show: Int32 = 1
        static let console: Int32 = 2
        static let inspect: Int32 = 3
        static let inspectAt: Int32 = 4
        static let close: Int32 = 5
    }

    let devToolsSetKeyHandler: @convention(c) (KeyFn?) -> Void
    /// Key downs the page left unhandled (`cmux_shim_set_unhandled_key_handler`).
    let setUnhandledKeyHandler: @convention(c) (KeyFn?) -> Void
    let devToolsSetPlacement: (Int32, CEFParentView?, Int32, Int32, Int32, Int32) -> Void
    let devToolsCommand: @convention(c) (Int32, Int32, Int32, Int32) -> Int32
    let devToolsBrowser: @convention(c) (Int32) -> Int32
    let devToolsSetFocus: @convention(c) (Int32, Int32) -> Void
    /// Opens DevTools on one frontend panel (`network`, `timeline`); 0 when gone or invalid.
    let devToolsShowPanel: (Int32, String?) -> Int32

    let extActions: (Int32, Int32) -> String?
    let extActionRun: (Int32, String?, Int32, Int32) -> Int32
    let extActionHidePopup: (Int32, String?) -> Void
    let extActionContextMenu: (Int32, String?, Int32, Int32) -> Void
    let free: @convention(c) (UnsafeMutablePointer<CChar>?) -> Void
    let tabNavigationState: (Int32) -> String?
    let tabRestoreNavigation: (Int32, String?) -> Int32
    let navigationRestoreSupported: @convention(c) () -> Int32
    // Fork API v3 (the shim returns 0/NULL on older forks).
    let extList: (Int32) -> String?
    let extSetEnabled: (Int32, String?, Int32) -> Int32
    let extUninstall: (Int32, String?) -> Int32
    let extReload: (Int32, String?) -> Int32
    let extMovePinned: (Int32, String?, Int32) -> Int32
    let extSetPinned: (Int32, String?, Int32) -> Int32
    let extOpenOptions: (Int32, String?) -> Int32
    let extLoadUnpacked: (Int32, String?) -> Int32
    /// 1 when the fork has `cmux_ext_load_command_line_async`; a mirror read in host mode.
    let extLoadLaterSupported: @convention(c) () -> Int32
    /// `--load-extension`'s load into a persistent context key's profile (context key, reply id, folder),
    /// answered by a CMUX_SHIM_REPLY under the reply id (``CEFBuiltInExtensionLoads``).
    let extLoadCommandLine: (String?, Int32, String?) -> Int32
    let extCommands: (Int32) -> String?
    let extCommandRun: (Int32, String?, String?) -> Int32
    let tabMoveToWindow: @convention(c) (Int32, Int32, Int32) -> Int32
    let contextMenuDone: @convention(c) (Int32, Int32, Int32) -> Void
    /// Answers a renderer hang: 0 waits, 1 ends the renderer.
    let unresponsiveReply: @convention(c) (Int32, Int32) -> Int32

    let closeAll: @convention(c) () -> Void
    let liveBrowserCount: @convention(c) () -> Int32
    let windowCount: @convention(c) () -> Int32
    let shutdown: @convention(c) () -> Void
    /// Chromium never shows a window of its own (fork API 8; no-op before).
    let setWindowRequestHandler: @convention(c) (WindowRequestFn?) -> Void
    /// `cmux_shim_set_window_request_policy`: windows, count, clicks, count, profile root, then the
    /// Cmd, Shift-Cmd, Shift, Option and middle click actions (`CEFWindowRequestPolicy`).
    let setWindowRequestPolicy: @convention(c) (
        UnsafeRawPointer?, Int32, UnsafeRawPointer?, Int32, UnsafePointer<CChar>?, Int32, Int32, Int32, Int32, Int32
    ) -> Void
    /// Chromium's own focus requests go through cmux (`CefFocusHandler`).
    let setFocusRequestHandler: @convention(c) (FocusRequestFn?) -> Void
    /// Browsers Chromium created outside cmux (fork API 8; -1 before).
    let foreignBrowserCount: @convention(c) () -> Int32
    /// Downloads (`CEFDownloads`): start one with a tab's context, answer
    /// DOWNLOAD_STARTED with a path ("" cancels), cancel/pause/resume.
    let downloadURL: (Int32, String?) -> Int32
    let downloadContinue: (Int32, String?) -> Int32
    let downloadControl: @convention(c) (Int32, Int32) -> Int32
    /// Answers PERMISSION_PROMPT: 1 allow, 2 deny, else no answer.
    let permissionContinue: @convention(c) (Int32, Int32) -> Int32

    // Page Info site state (ABI 3).
    let contentSetting: (Int32, String?, String?) -> Int32
    let setContentSetting: (Int32, String?, String?, Int32) -> Int32
    let visitCookies: @convention(c) (Int32, Int32) -> Int32
    let deleteCookies: (Int32, Int32, String?, String?) -> Int32
    /// A tab's favicon through its own request context (``CEFRuntime/favicon(_:url:maxPixels:)``).
    let downloadFavicon: (Int32, Int32, String?, Int32) -> Int32
    /// Browser import: cookies into a profile's request context.
    let importCookies: (String?, Int32, String?) -> Int32
    let clearCookies: (String?, Int32, Int64) -> Int32
    /// Browser import: saved passwords into a profile's password store
    /// (entries as raw `cmux_shim_password_entry` rows, see CEFRuntime+PasswordImport).
    let importPasswords: (String?, Int32, ChromiumPasswordRows) -> Int32
    let passwordEntrySize: @convention(c) () -> Int32
    let passwordImportAvailable: @convention(c) () -> Int32
    let replacePasswords: (String?, Int32, ChromiumPasswordRows) -> Int32
    let passwordReplaceAvailable: @convention(c) () -> Int32
    let passwordPromptAnswer: (Int32, Int32, String?) -> Int32
    let setPasswordGenerationEnabled: @convention(c) (Int32) -> Int32
    /// Password filling on or off in one tab (off while an agent drives it).
    let setPasswordFill: @convention(c) (Int32, Int32) -> Int32
    /// Profile (Touch ID) passkeys, metadata only (fork API 18; see CEFRuntime+Passkeys).
    let passkeysAvailable: @convention(c) () -> Int32
    let passkeysList: (String?, Int32) -> Int32
    let passkeyDelete: (String?, String?, Int32) -> Int32
    /// Password manager core (fork API 18; see CEFEngine+Passwords). The reveal callback gets
    /// the bytes in a shim buffer that is zeroed after it returns.
    typealias PasswordRevealCallback = @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?, Int) -> Void
    let passwordCoreAvailable: @convention(c) () -> Int32
    let passwordList: (String?, Int32) -> Int32
    /// Profile path, password ids, request id.
    let passwordRemove: (String?, [String], Int32) -> Int32
    let passwordExceptionRemove: (String?, String?, Int32) -> Int32
    let passwordSetUsername: (String?, String?, String?, Int32) -> Int32
    /// Profile path, password id, the reveal callback and its context (a +1 box the callback takes back).
    let passwordReveal: (String?, String?, PasswordRevealCallback?, UnsafeMutableRawPointer?) -> Int32
    let passwordExport: (String?, String?, Int32) -> Int32
    let sslStatus: (Int32) -> String?
    /// Clears the profile's certificate error decisions and connections.
    let clearCertificateExceptions: @convention(c) (Int32, Int32) -> Int32
    /// Answers the browser's next certificate error `code` on `host`: continue (0), or let
    /// Chromium's own interstitial decide (1); 0 when the browser is gone.
    let certificateProceed: (Int32, String?, Int32, Int32) -> Int32
    /// Distinct renderer client ids hosting the tab's frames.
    let rendererClientIDs: (_ browser: Int32, _ capacity: Int32) -> [Int32]
    /// Every browser's frames per renderer client id (``CEFRendererFrames``); nil when the list grew between
    /// the sizing call and the read (a partial list would hide frames). Empty in host mode.
    let rendererFrames: () -> [CEFRendererFrames.Entry]?
    /// The pid of the renderer hosting the tab's main frame (the fork's `cmux_cef_browser_renderer_pid`);
    /// 0 while none, on a fork without the call, and in host mode.
    let rendererPID: @convention(c) (Int32) -> Int32

    // Renderer paths that keep a tab off DevTools (fork API 29, `CEFForkFeatures.rendererPaths`), so
    // same-site tabs can share a renderer as in Chrome. Optional: a shim built before them lacks the
    // exports and still loads; `CEFForkFeatures` uses them only when all are there and the fork's API
    // is 29 or later.
    /// A document-start script for every browser: world ("" page), source, all frames, run now.
    let addDocumentScript: ((String?, String?, Int32, Int32) -> Int32)?
    /// `cmuxPost(channel, string)` in an isolated world: world, channel. Posts come as PAGE_MESSAGE.
    let addPageChannel: ((String?, String?) -> Int32)?
    /// Runs a script in the main frame: browser, token, world, script, user gesture. EVALUATE_RESULT answers.
    let tabEvaluate: ((Int32, Int32, String?, String?, Int32) -> Int32)?
    /// `WebContents::SetPageFrozen`: browser, frozen; 0 when the browser is gone or (freezing) visible.
    let tabSetFrozen: (@convention(c) (Int32, Int32) -> Int32)?
    /// `CefBrowserHost::SendMouseClickEvent` down and up: browser, x, y (view points), button, modifiers, clicks.
    let tabSendClick: (@convention(c) (Int32, Double, Double, Int32, Int32, Int32) -> Int32)?
    /// `CefBrowserHost::SendMouseMoveEvent` with no button held: browser, x, y (view points),
    /// modifiers. Nil without the export.
    let tabSendMouseMove: (@convention(c) (Int32, Double, Double, Int32) -> Int32)?
    /// The page's `prefers-color-scheme` (WebPreferences preferred_color_scheme): browser, 1 light, 2 dark.
    let tabSetColorScheme: (@convention(c) (Int32, Int32) -> Int32)?
    /// `WebContents::Discard` in place: browser; 1 discarded, 0 refused. Nil without the
    /// export and in host mode, whose return means only "sent" (the answer is a later REPLY).
    let tabDiscard: (@convention(c) (Int32) -> Int32)?
    /// The page as it last drew, with no DevTools agent (the fork's `cmux_browser_capture`):
    /// browser, reply id, max width, max height (pixels), format (``CEFSurfaceCopyFormat``), JPEG quality;
    /// 1 started. CMUX_SHIM_REPLY answers (``CEFTab/copySurface(maxPixelSize:)``). Nil without the export.
    let tabCopySurface: (@convention(c) (Int32, Int32, Int32, Int32, Int32, Int32) -> Int32)?
    let widgets: CEFShimWidgetOps
    /// Drops into a detached page (task 050, fork API 31).
    let dragTarget: CEFShimDragTargetOps
    /// Pointer lock and keyboard lock (task 229, fork API 31).
    let locks: CEFShimLockOps
    /// <select> popups as data (task 060, fork API 31).
    let popupMenus: CEFShimPopupMenuOps
    /// Autofill, password and `<datalist>` suggestions as data (task 061, fork API 31).
    let suggestions: CEFShimSuggestionOps
    /// The color chooser, device choosers and screen-share picker as data (task 228, fork API 31).
    let choosers: CEFShimChooserOps
    let textInput: CEFShimTextInputOps
    /// `cmux_shim_browser_attach_view(browser, parent_view)` (fork API 36, Track B): moves the
    /// browser's `WebContentsViewCocoa` into `parent_view` (an NSView), below its other subviews; 1 attached, 0
    /// refused (an unknown browser, no page window yet, a fork below API 36). Nil without the export and in host
    /// mode, where no view pointer crosses the process.
    let browserAttachView: ((Int32, CEFParentView?) -> Int32)?

    /// Every renderer-path export is there (`CEFForkFeatures`).
    var hasRendererPaths: Bool {
        addDocumentScript != nil && addPageChannel != nil && tabEvaluate != nil && tabSetFrozen != nil && tabSendClick != nil
            && tabSetColorScheme != nil
    }

    // Remote localhost (plans/cmux-next/remote-localhost.md).
    let setContextProxy: (String?, Int32) -> Int32
    let contextProxyState: (String?) -> Int32
    let setContextProxyServer: (String?, String?, String?) -> Int32
    let releaseContext: (String?) -> Void
    let setNavigationGuard: @convention(c) (Int32, Int32) -> Void
    /// A sign-in tab's callback: scheme, https host, https path (all empty clears).
    let setAuthCallback: (Int32, String?, String?, String?) -> Void

    // Allowlisted boolean profile preferences (password and autofill settings).
    /// JSON {"value", "modifiable"}, freed with `freeOwned`; NULL for an
    /// unknown profile or a name not allowed.
    let prefGet: (String?, String?) -> String?
    /// 1 set, 0 not modifiable or not allowed, -1 refused.
    let prefSetBool: (String?, String?, Int32) -> Int32
    let prefWatch: (String?, String?, Int32) -> Int32
    /// The chrome.bookmarks bridge: profile cache path, tree JSON; 1, 0 not loaded, -1 refused.
    let bookmarksSync: (String?, String?) -> Int32
    /// cmux-page://<id>/ from a folder: id, resource root, CSP (NULL = default).
    let pageSchemeAdd: (String?, String?, String?) -> Int32
    /// The same for reserved (`cmux.`) ids only: the first-party path (`CEFPageSchemes`).
    let pageSchemeAddFirstParty: (String?, String?, String?) -> Int32
    /// The same with the page's dynamic prefixes (newline-separated), which the page host answers,
    /// and the file `/` serves (NULL = index.html).
    let pageSchemeAddFirstPartyDynamic: (String?, String?, String?, String?, String?) -> Int32
    /// The renderer group of a first-party page: id, group name (`privileged`); 1 set,
    /// 0 an unknown id or group. Call before `CefInitialize` ends. Optional: a fork before page groups
    /// has no such export (nil) and still loads, with no page in a group.
    let pageSchemeSetGroup: ((String?, String?) -> Int32)?
    /// Answers a PAGE_RESOURCE request: token, status, MIME, body, length; 1 when it was waiting.
    let pageResourceRespond: (Int32, Int32, String?, Data) -> Int32

    // Extension UI the app draws (fork API 12; no-ops and 0/NULL before).
    let setNewTabPageURL: (String?) -> Void
    let addNativeMessagingDir: (String?, Int32) -> Int32
    let installPromptReply: @convention(c) (Int32, Int32) -> Int32
    let omniboxKeywords: (Int32) -> String?
    let omniboxInput: (Int32, String?, Int32, String?, Int32) -> Int32
    // Popup windows (fork API 11): exposed for the popup panel; not enabled yet.
    let setPopupWindowsEnabled: @convention(c) (Int32) -> Void
    let popupWindowBounds: (Int32) -> CEFShimBounds
    let popupWindowAttach: (Int32, CEFParentView?, Int32, Int32) -> Int32
    // DevTools device mode (fork API 24).
    let devToolsInspectedBounds: (Int32) -> CEFShimBounds
    // Side panel header (fork API 13).
    let sidePanelState: (Int32) -> String?
    let sidePanelPress: (Int32, String?) -> Int32

    /// Opens the shim at `url`, resolves every symbol and checks that its ABI
    /// identity is `expected` (`CEFShimABI.bundledIdentity()`).
    static func open(_ url: URL, expected: String?) throws(LoadError) -> CEFShimLibrary {
        // SAFETY: dlopen reads the NUL-terminated copy of the path Swift makes for the call.
        guard let handle = unsafe dlopen(url.path, RTLD_NOW | RTLD_LOCAL) else {
            // SAFETY: after a failed dlopen, dlerror returns its NUL-terminated message; it is copied at once.
            throw .open(unsafe String(cString: dlerror()))
        }
        // SAFETY: the handle is never closed, so every symbol dlsym finds stays mapped for the process;
        // the resolver casts each to its export's C type only after this shim's ABI identity is read.
        let library = try unsafe CEFShimLibrary(Resolver(symbol: { unsafe dlsym(handle, $0) }))
        try checkABI(expected: expected, found: library.abiID())
        return library
    }

    /// Where every function came from (``overriding(_:)`` resolves the others the same way).
    let resolver: Resolver
}
