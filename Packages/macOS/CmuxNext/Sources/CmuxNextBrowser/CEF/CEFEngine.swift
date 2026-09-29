public import Foundation

/// The Chromium engine: the patched CEF fork (manaflow-ai/cef, Chrome style
/// with real Chrome extensions), embedded as child windows that track the
/// pane (plans/cmux-next/browser.md section 3).
///
/// CEF loads lazily. `availability` only checks that the runtime was
/// embedded in the app bundle (scripts/cmux-next/embed-cef.sh); the first
/// `makeTab` loads the shim and the framework and runs `CefInitialize` with an
/// external message pump.
public final class CEFEngine: BrowserEngine {
    public let kind: BrowserEngineKind = .cef

    public let capabilities: BrowserCapabilities = [
        .cdp, .extensions, .trustedInput, .networkIntercept, .crossOriginFrames,
        .devTools, .downloads, .snapshots, .findMatchCount,
    ]

    private let layout: CEFRuntimeLayout?

    /// `layout` defaults to the runtime embedded in the main bundle, or the
    /// directory named by `CMUX_NEXT_CEF_RUNTIME`.
    public init(layout: CEFRuntimeLayout? = CEFRuntimeLayout.locate()) {
        self.layout = layout
    }

    public var availability: BrowserEngineAvailability {
        guard layout != nil else { return .unavailable(reason: Strings.cefUnavailable) }
        if case .failed(let reason) = CEFRuntime.shared.state { return .unavailable(reason: reason) }
        return .available
    }

    /// True once CEF has been initialized in this process.
    public var isRunning: Bool { CEFRuntime.shared.state == .ready }

    public func makeTab(_ configuration: BrowserTabConfiguration) async throws -> any BrowserTab {
        try makeCEFTab(configuration)
    }

    /// Synchronous tab creation (initializes CEF on first use).
    public func makeCEFTab(_ configuration: BrowserTabConfiguration) throws -> CEFTab {
        let runtime = CEFRuntime.shared
        try runtime.start(layout: layout)
        let pane = configuration.pane ?? BrowserPaneID(rawValue: "tab-" + configuration.id.rawValue)
        let host = runtime.host(for: CEFPaneKey(pane: pane, profile: configuration.profile))
        let tab = CEFTab(id: configuration.id, profile: configuration.profile, host: host, runtime: runtime)
        host.add(tab)
        if configuration.zoom != 1 { tab.setZoom(configuration.zoom) }
        if let url = configuration.initialURL { tab.load(url) }
        return tab
    }

    /// Quit ordering for a live CEF: closes every browser, waits (async, the
    /// run loop keeps pumping) until the fork reports no Chromium windows or
    /// `timeout` passes, then calls CefShutdown. The App awaits this from
    /// `applicationShouldTerminate`. No-op when CEF never started.
    public func shutdown(timeout: Duration = .seconds(3)) async {
        await CEFRuntime.shared.shutdown(timeout: timeout)
    }
}
