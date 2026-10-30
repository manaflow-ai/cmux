// The Developer Tools set of the command palette (plans/cmux-next/web-devtools.md):
// Chromium DevTools' Command Menu and Safari's Develop menu, for the focused web
// view. The App binds one handler per `WebDevToolsCommand` (CmuxNextBrowser),
// whose raw values are these ids after `devtools.`; a command the engine cannot
// run stays listed, disabled, with the reason. Titles live in DevToolsActions.xcstrings.

nonisolated extension BrowserActionCatalog {
    static func devToolsDescriptors() -> [ActionDescriptor] {
        [
            devTools("openDocked", t("action.devtools.openDocked", "Developer Tools: Open Docked"), "rectangle.bottomhalf.inset.filled",
                     ["devtools", "inspector", "dock", "bottom", "open"]),
            devTools("openDockedRight", t("action.devtools.openDockedRight", "Developer Tools: Dock to Right"), "rectangle.righthalf.inset.filled",
                     ["devtools", "inspector", "dock", "right", "side"]),
            devTools("openInWindow", t("action.devtools.openInWindow", "Developer Tools: Open in Separate Window"), "macwindow",
                     ["devtools", "inspector", "undock", "window", "detach"]),
            devTools("close", t("action.devtools.close", "Developer Tools: Close"), "xmark.rectangle",
                     ["devtools", "inspector", "close", "hide"]),
            devTools("showElements", t("action.devtools.showElements", "Developer Tools: Show Elements"), "chevron.left.forwardslash.chevron.right",
                     ["devtools", "panel", "elements", "dom", "html", "css"]),
            devTools("showSources", t("action.devtools.showSources", "Developer Tools: Show Sources"), "doc.text",
                     ["devtools", "panel", "sources", "debugger", "breakpoints", "scripts", "resources"]),
            devTools("showNetwork", t("action.devtools.showNetwork", "Developer Tools: Show Network"), "network",
                     ["devtools", "panel", "network", "requests", "xhr", "fetch"]),
            devTools("showPerformance", t("action.devtools.showPerformance", "Developer Tools: Show Performance"), "gauge.with.dots.needle.33percent",
                     ["devtools", "panel", "performance", "timeline", "profiler"]),
            devTools("showMemory", t("action.devtools.showMemory", "Developer Tools: Show Memory"), "memorychip",
                     ["devtools", "panel", "memory", "heap", "leak"]),
            devTools("showApplication", t("action.devtools.showApplication", "Developer Tools: Show Application"), "externaldrive",
                     ["devtools", "panel", "application", "storage", "cookies", "local storage", "service worker", "cache"]),
            devTools("showLighthouse", t("action.devtools.showLighthouse", "Developer Tools: Show Lighthouse"), "light.beacon.max",
                     ["devtools", "panel", "lighthouse", "audits", "accessibility", "seo"]),
            devTools("showLayers", t("action.devtools.showLayers", "Developer Tools: Show Layers"), "square.3.layers.3d",
                     ["devtools", "panel", "layers", "compositing"]),
            devTools("showRendering", t("action.devtools.showRendering", "Developer Tools: Show Rendering"), "paintbrush",
                     ["devtools", "drawer", "rendering", "paint"]),
            devTools("showSensors", t("action.devtools.showSensors", "Developer Tools: Show Sensors"), "location",
                     ["devtools", "drawer", "sensors", "geolocation", "orientation", "touch"]),
            devTools("showSecurity", t("action.devtools.showSecurity", "Developer Tools: Show Security"), "lock.shield",
                     ["devtools", "panel", "security", "certificate", "https"]),
            devTools("showAnimations", t("action.devtools.showAnimations", "Developer Tools: Show Animations"), "film",
                     ["devtools", "drawer", "animations"]),
            devTools("pauseScript", t("action.devtools.pauseScript", "Developer Tools: Pause Script Execution"), "pause.circle",
                     ["devtools", "debugger", "pause", "break"]),
            devTools("resumeScript", t("action.devtools.resumeScript", "Developer Tools: Resume Script Execution"), "play.circle",
                     ["devtools", "debugger", "resume", "continue"]),
            devTools("clearConsole", t("action.devtools.clearConsole", "Developer Tools: Clear Console"), "clear",
                     ["devtools", "console", "clear"]),
            devTools("copyConsoleLog", t("action.devtools.copyConsoleLog", "Developer Tools: Copy Console Log"), "doc.on.clipboard",
                     ["devtools", "console", "log", "copy", "save"]),
            devTools("toggleCache", t("action.devtools.toggleCache", "Developer Tools: Disable Cache"), "archivebox",
                     ["devtools", "network", "cache", "disable"]),
            devTools("throttleOffline", t("action.devtools.throttleOffline", "Network: Go Offline"), "wifi.slash",
                     ["devtools", "network", "throttle", "offline"]),
            devTools("throttleSlow3G", t("action.devtools.throttleSlow3G", "Network: Throttle to Slow 3G"), "tortoise",
                     ["devtools", "network", "throttle", "slow", "3g"]),
            devTools("throttleFast3G", t("action.devtools.throttleFast3G", "Network: Throttle to Fast 3G"), "hare",
                     ["devtools", "network", "throttle", "fast", "3g", "4g"]),
            devTools("throttleOff", t("action.devtools.throttleOff", "Network: No Throttling"), "wifi",
                     ["devtools", "network", "throttle", "online", "reset"]),
            devTools("emptyCacheAndHardReload", t("action.devtools.emptyCacheAndHardReload", "Developer Tools: Empty Cache and Hard Reload"), "arrow.clockwise.circle",
                     ["devtools", "reload", "cache", "empty", "hard"]),
            devTools("clearSiteData", t("action.devtools.clearSiteData", "Developer Tools: Clear Site Data and Cookies"), "trash",
                     ["devtools", "storage", "cookies", "site data", "clear"]),
            devTools("toggleJavaScript", t("action.devtools.toggleJavaScript", "Developer Tools: Disable JavaScript"), "curlybraces",
                     ["devtools", "javascript", "js", "scripts", "disable"]),
            devTools("toggleCSS", t("action.devtools.toggleCSS", "Developer Tools: Disable CSS"), "paintpalette",
                     ["devtools", "css", "styles", "disable"]),
            devTools("toggleReducedMotion", t("action.devtools.toggleReducedMotion", "Rendering: Emulate Reduced Motion"), "figure.walk.motion",
                     ["devtools", "rendering", "prefers-reduced-motion", "animation", "accessibility"]),
            devTools("toggleFocusEmulation", t("action.devtools.toggleFocusEmulation", "Rendering: Emulate a Focused Page"), "scope",
                     ["devtools", "rendering", "focus", "emulate"]),
            devTools("togglePaintFlashing", t("action.devtools.togglePaintFlashing", "Rendering: Show Paint Flashing"), "rectangle.dashed",
                     ["devtools", "rendering", "paint", "flashing", "repaint"]),
            devTools("toggleLayoutShiftRegions", t("action.devtools.toggleLayoutShiftRegions", "Rendering: Show Layout Shift Regions"), "rectangle.2.swap",
                     ["devtools", "rendering", "layout shift", "cls"]),
            devTools("toggleLayerBorders", t("action.devtools.toggleLayerBorders", "Rendering: Show Layer Borders"), "square.dashed",
                     ["devtools", "rendering", "layers", "borders", "compositing"]),
            devTools("toggleFPSMeter", t("action.devtools.toggleFPSMeter", "Rendering: Show Frame Rendering Stats"), "speedometer",
                     ["devtools", "rendering", "fps", "frames", "meter"]),
            devTools("togglePerformanceRecording", t("action.devtools.togglePerformanceRecording", "Developer Tools: Start/Stop Performance Recording"), "record.circle",
                     ["devtools", "performance", "record", "profile", "timeline"]),
            devTools("takeHeapSnapshot", t("action.devtools.takeHeapSnapshot", "Developer Tools: Take Heap Snapshot"), "camera.metering.matrix",
                     ["devtools", "memory", "heap", "snapshot"]),
            devTools("captureScreenshot", t("action.devtools.captureScreenshot", "Developer Tools: Capture Screenshot"), "camera",
                     ["devtools", "screenshot", "capture", "viewport"]),
            devTools("captureFullPageScreenshot", t("action.devtools.captureFullPageScreenshot", "Developer Tools: Capture Full Size Screenshot"), "camera.viewfinder",
                     ["devtools", "screenshot", "capture", "full page"]),
            devTools("captureNodeScreenshot", t("action.devtools.captureNodeScreenshot", "Developer Tools: Capture Node Screenshot"), "camera.on.rectangle",
                     ["devtools", "screenshot", "capture", "node", "element"]),
            devTools("viewPageSource", t("action.devtools.viewPageSource", "Developer Tools: View Page Source"), "chevron.left.slash.chevron.right",
                     ["devtools", "source", "html", "view-source"]),
        ]
    }

    /// A palette command on the focused web view. Hidden while no web view has
    /// focus (`webViewFocused`); no CLI verb (it drives the tools' UI) and no
    /// menu row (the page menu's Inspect folder offers Developer Tools).
    private static func devTools(_ id: String, _ title: String, _ symbol: String, _ keywords: [String]) -> ActionDescriptor {
        var descriptor = ActionDescriptor(
            id: ActionID(rawValue: "devtools.\(id)"), title: title, keywords: ["developer tools", "web inspector"] + keywords,
            category: .browser, symbol: symbol, surfaces: [.palette], requires: [.webViewFocused], targets: [.pane], destructive: id == "clearSiteData",
            surfacePlan: ActionSurfacePlan(cli: .exempt(.guiOnly), contextMenuExemption: .familyMember)
        )
        // Capture commands call the page engine directly. Until they share the browser host's
        // secret masker, only an in-app person's palette run may receive their pixels.
        if id.hasPrefix("capture") { descriptor.isPersonOnly = true }
        return descriptor
    }

    private static func t(_ key: StaticString, _ english: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: english, table: "DevToolsActions", bundle: .module)
    }
}
