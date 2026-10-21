/// One developer-tools command of the palette's Developer Tools set
/// (plans/cmux-next/web-devtools.md): open the tools, show a panel, or
/// change how the page runs (cache, network, rendering, scripts).
///
/// The command palette offers each case as the action `devtools.<rawValue>`
/// (``actionID``). Each command works on the focused web view: a WebKit or
/// Chromium browser tab, or any other `WKWebView` in the app (Markdown,
/// agent chats, internal pages). ``support(on:isBrowserTab:)`` says whether
/// an engine can run it; a command an engine cannot run stays in the palette,
/// disabled, with the ``WebDevToolsLimit`` as its reason.
public nonisolated enum WebDevToolsCommand: String, CaseIterable, Hashable, Sendable {
    // Open and place the tools.
    case openDocked
    case openDockedRight
    case openInWindow
    case close

    // Panels (Chromium's Command Menu "Show …" commands).
    case showElements
    case showSources
    case showNetwork
    case showPerformance
    case showMemory
    case showApplication
    case showLighthouse
    case showLayers
    case showRendering
    case showSensors
    case showSecurity
    case showAnimations

    // Debugger and console.
    case pauseScript
    case resumeScript
    case clearConsole
    case copyConsoleLog

    // Network.
    case toggleCache
    case throttleOffline
    case throttleSlow3G
    case throttleFast3G
    case throttleOff
    case emptyCacheAndHardReload
    case clearSiteData

    // Page behavior and rendering.
    case toggleJavaScript
    case toggleCSS
    case toggleReducedMotion
    case toggleFocusEmulation
    case togglePaintFlashing
    case toggleLayoutShiftRegions
    case toggleLayerBorders
    case toggleFPSMeter

    // Recording and capture.
    case togglePerformanceRecording
    case takeHeapSnapshot
    case captureScreenshot
    case captureFullPageScreenshot
    case captureNodeScreenshot
    case viewPageSource

    /// The action id the palette, menus and `cmux action run` use.
    public var actionID: String { "devtools.\(rawValue)" }

    /// The command for an action id from ``actionID``, or nil.
    public init?(actionID: String) {
        guard actionID.hasPrefix("devtools.") else { return nil }
        self.init(rawValue: String(actionID.dropFirst("devtools.".count)))
    }

    /// The panel a `show…` command selects.
    public var panel: WebDevToolsPanel? {
        switch self {
        case .showElements: .elements
        case .showSources: .sources
        case .showNetwork: .network
        case .showPerformance: .performance
        case .showMemory: .memory
        case .showApplication: .application
        case .showLighthouse: .lighthouse
        case .showLayers: .layers
        case .showRendering: .rendering
        case .showSensors: .sensors
        case .showSecurity: .security
        case .showAnimations: .animations
        default: nil
        }
    }

    /// The network condition a `throttle…` command sets.
    public var throttle: WebDevToolsThrottle? {
        switch self {
        case .throttleOffline: .offline
        case .throttleSlow3G: .slow3G
        case .throttleFast3G: .fast3G
        case .throttleOff: WebDevToolsThrottle.none
        default: nil
        }
    }

    /// Whether the command switches a mode on and off (the palette shows a
    /// check while it is on).
    public var isToggle: Bool {
        switch self {
        case .toggleCache, .toggleJavaScript, .toggleCSS, .toggleReducedMotion, .toggleFocusEmulation,
             .togglePaintFlashing, .toggleLayoutShiftRegions, .toggleLayerBorders, .toggleFPSMeter:
            true
        default:
            false
        }
    }

    /// Whether `engine` can run the command on its page.
    ///
    /// - Parameters:
    ///   - engine: The page's engine. A `WKWebView` that is not a browser
    ///     tab (Markdown, an agent chat) is `.webkit`.
    ///   - isBrowserTab: The target is a browser tab, not another web view
    ///     (full-page capture and View Page Source need the tab).
    /// - Returns: `.supported`, or `.limited` with the reason to show.
    public func support(on engine: BrowserEngineKind, isBrowserTab: Bool = true) -> WebDevToolsSupport {
        switch engine {
        case .cef: chromiumSupport
        case .webkit: webKitSupport(isBrowserTab: isBrowserTab)
        }
    }

    /// Chromium pages are always browser tabs; its DevTools has every panel.
    private var chromiumSupport: WebDevToolsSupport {
        switch self {
        case .togglePerformanceRecording: .limited(.useRecordButton)
        case .takeHeapSnapshot: .limited(.useHeapSnapshotButton)
        case .captureNodeScreenshot: .limited(.useNodeMenu)
        case .copyConsoleLog: .limited(.useConsoleSaveAs)
        default: .supported
        }
    }

    private func webKitSupport(isBrowserTab: Bool) -> WebDevToolsSupport {
        if let panel {
            if panel == .lighthouse { return .limited(.chromiumOnly) }
            return panel.webKitSelector == nil ? .limited(.webKitNoPanelCommand) : .supported
        }
        switch self {
        case .openDocked, .openInWindow, .close, .clearConsole, .emptyCacheAndHardReload, .clearSiteData,
             .toggleCSS, .togglePerformanceRecording, .captureScreenshot, .viewPageSource:
            return .supported
        case .captureFullPageScreenshot:
            return isBrowserTab ? .supported : .limited(.browserTabOnly)
        case .openDockedRight: return .limited(.webKitDockSide)
        case .takeHeapSnapshot: return .limited(.webKitUseTimelines)
        case .captureNodeScreenshot: return .limited(.webKitUseNodeMenu)
        case .copyConsoleLog: return .limited(.useConsoleSaveAs)
        default: return .limited(.chromiumOnly)
        }
    }
}
