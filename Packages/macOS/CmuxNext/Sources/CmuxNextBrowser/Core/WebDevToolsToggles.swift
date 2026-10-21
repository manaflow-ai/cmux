/// The developer-tools modes of one Chromium page (cache off, throttling,
/// paint flashing...) and the DevTools protocol calls that change them.
///
/// Chromium keeps these per DevTools session, and cmux's session lives as
/// long as the tab, so the modes hold across navigations until switched
/// off. The color scheme shares `Emulation.setEmulatedMedia` with reduced
/// motion: both are sent together so one never clears the other.
///
/// ```swift
/// var modes = WebDevToolsToggles()
/// let calls = modes.calls(for: .toggleCache, origin: nil)
/// // [Network.enable, Network.setCacheDisabled {cacheDisabled: true}]
/// ```
public nonisolated struct WebDevToolsToggles: Hashable, Sendable {
    /// The toggles that are on.
    public private(set) var on: Set<WebDevToolsCommand> = []
    /// The network condition (`.none`: no throttling).
    public private(set) var throttle: WebDevToolsThrottle = .none
    /// The emulated `prefers-color-scheme` ("" for the system's).
    public var colorScheme = ""

    public init() {}

    /// Whether `command` (a toggle or a throttle preset) is on.
    public func isOn(_ command: WebDevToolsCommand) -> Bool {
        if let preset = command.throttle { return preset != .none && preset == throttle }
        return on.contains(command)
    }

    /// The `Emulation.setEmulatedMedia` call for the color scheme and
    /// reduced motion together.
    public var emulatedMedia: WebDevToolsProtocolCall {
        let motion = on.contains(.toggleReducedMotion) ? "reduce" : ""
        let features: [[String: any Sendable]] = [
            ["name": "prefers-color-scheme", "value": colorScheme],
            ["name": "prefers-reduced-motion", "value": motion],
        ]
        return WebDevToolsProtocolCall("Emulation.setEmulatedMedia", ["features": features])
    }

    /// Records the change `command` makes and returns the protocol calls
    /// that make it, or nil when the command is not a protocol command
    /// (panels, scripts, captures).
    ///
    /// - Parameter origin: The page's origin, for Clear Site Data.
    public mutating func calls(for command: WebDevToolsCommand, origin: String?) -> [WebDevToolsProtocolCall]? {
        if let preset = command.throttle {
            throttle = preset
            return [WebDevToolsProtocolCall("Network.enable"),
                    WebDevToolsProtocolCall("Network.emulateNetworkConditions", preset.parameters)]
        }
        let enabled = command.isToggle ? flip(command) : true
        switch command {
        case .toggleCache:
            return [WebDevToolsProtocolCall("Network.enable"),
                    WebDevToolsProtocolCall("Network.setCacheDisabled", ["cacheDisabled": enabled])]
        case .toggleJavaScript:
            // On means JavaScript is off: the toggle is "Disable JavaScript".
            return [WebDevToolsProtocolCall("Emulation.setScriptExecutionDisabled", ["value": enabled])]
        case .toggleReducedMotion:
            return [emulatedMedia]
        case .toggleFocusEmulation:
            return [WebDevToolsProtocolCall("Emulation.setFocusEmulationEnabled", ["enabled": enabled])]
        case .togglePaintFlashing:
            return overlay("Overlay.setShowPaintRects", ["result": enabled])
        case .toggleLayoutShiftRegions:
            return overlay("Overlay.setShowLayoutShiftRegions", ["result": enabled])
        case .toggleLayerBorders:
            return overlay("Overlay.setShowDebugBorders", ["show": enabled])
        case .toggleFPSMeter:
            return overlay("Overlay.setShowFPSCounter", ["show": enabled])
        case .pauseScript:
            return [WebDevToolsProtocolCall("Debugger.enable"), WebDevToolsProtocolCall("Debugger.pause")]
        case .resumeScript:
            return [WebDevToolsProtocolCall("Debugger.resume")]
        case .emptyCacheAndHardReload:
            return [WebDevToolsProtocolCall("Network.clearBrowserCache"),
                    WebDevToolsProtocolCall("Page.reload", ["ignoreCache": true])]
        case .clearSiteData:
            guard let origin else { return [] }
            return [WebDevToolsProtocolCall("Storage.clearDataForOrigin", ["origin": origin, "storageTypes": "all"])]
        default:
            return nil
        }
    }

    private mutating func flip(_ command: WebDevToolsCommand) -> Bool {
        if on.remove(command) != nil { return false }
        on.insert(command)
        return true
    }

    /// Overlay methods need the DOM and Overlay domains on.
    private func overlay(_ method: String, _ params: [String: any Sendable]) -> [WebDevToolsProtocolCall] {
        [WebDevToolsProtocolCall("DOM.enable"), WebDevToolsProtocolCall("Overlay.enable"), WebDevToolsProtocolCall(method, params)]
    }
}
