import Foundation

/// One `mirror` export of plans/cmux-next/chromium-host-ops.json, named by its `mirror_key`, with
/// the events whose batch refreshes it (`refresh_events`; CEFDeferredEventsTests checks both against
/// the JSON).
nonisolated enum CEFMirrorField: String, CaseIterable, Sendable {
    case forkAPIVersion = "host.fork_api_version"
    case placeholderSupported = "host.placeholder_supported"
    case navigationRestoreSupported = "host.navigation_restore_supported"
    case foreignBrowserCount = "host.foreign_browser_count"
    case liveBrowserCount = "host.live_browser_count"
    case windowCount = "host.window_count"
    case passwordImportAvailable = "host.password_import_available"
    case passwordReplaceAvailable = "host.password_replace_available"
    case passkeysAvailable = "host.passkeys_available"
    case passwordCoreAvailable = "host.password_core_available"
    case extLoadLaterSupported = "host.ext_load_later_supported"
    case navigationEntries = "tab.navigation_entries[browser_id]"
    case navigationState = "tab.navigation_state[browser_id]"
    case windowID = "tab.window_id[browser_id]"
    case devToolsBrowser = "tab.devtools_browser[browser_id]"
    case extActions = "tab.ext_actions[browser_id,icon_px]"
    case extList = "tab.ext_list[browser_id]"
    case extCommands = "tab.ext_commands[browser_id]"
    case sidePanelState = "tab.side_panel_state[browser_id]"
    case omniboxKeywords = "tab.omnibox_keywords[browser_id]"
    case devToolsInspectedBounds = "tab.devtools_inspected_bounds[browser_id]"
    case rendererClientIDs = "tab.renderer_client_ids[browser_id]"
    case popupWindowBounds = "popup_window.bounds[window_id]"

    /// The shim export the key answers.
    var export: String {
        switch self {
        case .forkAPIVersion: "cmux_shim_fork_api_version"
        case .placeholderSupported: "cmux_shim_placeholder_supported"
        case .navigationRestoreSupported: "cmux_shim_navigation_restore_supported"
        case .foreignBrowserCount: "cmux_shim_foreign_browser_count"
        case .liveBrowserCount: "cmux_shim_live_browser_count"
        case .windowCount: "cmux_shim_window_count"
        case .passwordImportAvailable: "cmux_shim_password_import_available"
        case .passwordReplaceAvailable: "cmux_shim_password_replace_available"
        case .passkeysAvailable: "cmux_shim_passkeys_available"
        case .passwordCoreAvailable: "cmux_shim_password_core_available"
        case .extLoadLaterSupported: "cmux_shim_ext_load_later_supported"
        case .navigationEntries: "cmux_shim_tab_navigation_entries"
        case .navigationState: "cmux_shim_tab_navigation_state"
        case .windowID: "cmux_shim_tab_window_id"
        case .devToolsBrowser: "cmux_shim_devtools_browser"
        case .extActions: "cmux_shim_ext_actions"
        case .extList: "cmux_shim_ext_list"
        case .extCommands: "cmux_shim_ext_commands"
        case .sidePanelState: "cmux_shim_side_panel_state"
        case .omniboxKeywords: "cmux_shim_omnibox_keywords"
        case .devToolsInspectedBounds: "cmux_shim_devtools_inspected_bounds"
        case .rendererClientIDs: "cmux_shim_renderer_client_ids"
        case .popupWindowBounds: "cmux_shim_popup_window_bounds"
        }
    }

    /// The host's hello (the `attach` pseudo-event) carries every host-wide key.
    var isHostWide: Bool { rawValue.hasPrefix("host.") }

    /// A fork capability, fixed for the host's life: only the hello carries it.
    var isCapability: Bool { isHostWide && refreshEvents.isEmpty }

    /// The events whose batch refreshes the key, besides the hello.
    var refreshEvents: Set<CEFMirrorTrigger> {
        switch self {
        case .forkAPIVersion, .placeholderSupported, .navigationRestoreSupported, .passwordImportAvailable,
             .passwordReplaceAvailable, .passkeysAvailable, .passwordCoreAvailable, .extLoadLaterSupported:
            []
        case .foreignBrowserCount: [.tab(.foreignBrowserBlocked), .tab(.windowDestroyed)]
        case .liveBrowserCount: [.afterCreated, .beforeClose]
        case .windowCount: [.afterCreated, .tab(.windowDestroyed), .beforeClose]
        case .navigationEntries: [.afterCreated, .address, .title, .loadStart, .loadingState, .beforeClose]
        case .navigationState: [.afterCreated, .address, .loadStart, .loadEnd, .loadingState, .beforeClose]
        case .windowID: [.afterCreated, .tab(.inserted), .tab(.moved), .tab(.removed), .beforeClose]
        case .devToolsBrowser: [.devToolsOpened, .devToolsClosed, .beforeClose]
        case .extActions: [.afterCreated, .tab(.extensionActionsChanged), .tab(.extensionsChanged), .address]
        case .extList, .extCommands, .omniboxKeywords: [.afterCreated, .tab(.extensionsChanged)]
        case .sidePanelState: [.afterCreated, .tab(.inserted), .tab(.moved), .tab(.sidePanelChanged)]
        case .devToolsInspectedBounds: [.tab(.devToolsDeviceMode), .devToolsClosed, .beforeClose]
        case .rendererClientIDs: [.afterCreated, .address, .loadEnd, .renderTerminated, .frameRenderers, .beforeClose]
        case .popupWindowBounds: [.tab(.popupWindowCreated), .tab(.popupWindowBounds), .tab(.windowDestroyed)]
        }
    }

    /// The keys a batch with `trigger` refreshes: the hello carries every host-wide key.
    static func refreshed(by trigger: CEFMirrorTrigger) -> [CEFMirrorField] {
        allCases.filter { trigger == .hello ? $0.isHostWide : $0.refreshEvents.contains(trigger) }
    }

    /// The key's id in a batch about `browser` in `window`: 0 for a host-wide key, the window for
    /// `popup_window.bounds`, the browser for every other key.
    func keyID(browser: Int32, window: Int32) -> Int32 {
        if isHostWide { return 0 }
        return self == .popupWindowBounds ? window : browser
    }
}

/// An event kind (`cmux_shim_event_kind_t`) and, for CMUX_SHIM_TAB_EVENT, its sub-kind.
nonisolated struct CEFMirrorTrigger: Hashable, Sendable {
    let kind: Int32
    let tabEvent: Int32?

    init(kind: Int32, tabEvent: Int32? = nil) {
        self.kind = kind
        self.tabEvent = tabEvent
    }

    /// CONTEXT_INITIALIZED: in process, the stand-in for the host's hello (`attach`), the first
    /// point where Chromium can answer the counts.
    static let hello = CEFMirrorTrigger(kind: 1)
    static let afterCreated = CEFMirrorTrigger(kind: 2)
    static let beforeClose = CEFMirrorTrigger(kind: 3)
    static let address = CEFMirrorTrigger(kind: 4)
    static let title = CEFMirrorTrigger(kind: 5)
    static let loadingState = CEFMirrorTrigger(kind: 7)
    static let loadStart = CEFMirrorTrigger(kind: 8)
    static let loadEnd = CEFMirrorTrigger(kind: 9)
    static let devToolsOpened = CEFMirrorTrigger(kind: 21)
    static let devToolsClosed = CEFMirrorTrigger(kind: 22)
    static let renderTerminated = CEFMirrorTrigger(kind: 23)
    static let frameRenderers = CEFMirrorTrigger(kind: 67)
    static func tab(_ event: CEFForkTabEvent) -> CEFMirrorTrigger { CEFMirrorTrigger(kind: 16, tabEvent: event.rawValue) }
}

extension CEFShimEvent {
    /// The trigger of an event that refreshes mirror keys, with its browser and window ids.
    nonisolated var mirrorTrigger: (trigger: CEFMirrorTrigger, browser: Int32, window: Int32)? {
        switch self {
        case .contextInitialized: (CEFMirrorTrigger.hello, 0, 0)
        case .afterCreated(let browser, _, let window, _): (CEFMirrorTrigger.afterCreated, browser, window)
        case .beforeClose(let browser): (CEFMirrorTrigger.beforeClose, browser, 0)
        case .address(let browser, _): (CEFMirrorTrigger.address, browser, 0)
        case .title(let browser, _): (CEFMirrorTrigger.title, browser, 0)
        case .loadingState(let browser, _, _, _): (CEFMirrorTrigger.loadingState, browser, 0)
        case .loadStart(let browser, _, _): (CEFMirrorTrigger.loadStart, browser, 0)
        case .loadEnd(let browser, _): (CEFMirrorTrigger.loadEnd, browser, 0)
        case .tab(let kind, let browser, let window, _): (CEFMirrorTrigger.tab(kind), browser, window)
        case .devToolsOpened(let browser, _, _): (CEFMirrorTrigger.devToolsOpened, browser, 0)
        case .devToolsClosed(let browser, _): (CEFMirrorTrigger.devToolsClosed, browser, 0)
        case .renderTerminated(let browser, _, _, _, _, _): (CEFMirrorTrigger.renderTerminated, browser, 0)
        case .frameRenderers(let browser): (CEFMirrorTrigger.frameRenderers, browser, 0)
        default: nil
        }
    }
}
