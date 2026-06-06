import AppKit
import Foundation
import CMUXCEFBridge

/// Receives navigation and document lifecycle callbacks for a single
/// `CEFBrowser`. All methods are invoked on the `MainActor`.
@MainActor
public protocol CEFBrowserDelegate: AnyObject {
    func cefBrowserDidStartLoading(_ browser: CEFBrowser)
    func cefBrowserDidFinishLoading(_ browser: CEFBrowser)
    func cefBrowser(_ browser: CEFBrowser, didChangeTitle title: String)
    func cefBrowser(_ browser: CEFBrowser, didChangeURL url: URL)
    func cefBrowser(_ browser: CEFBrowser, didFailLoad error: Error)
}

public extension CEFBrowserDelegate {
    func cefBrowserDidStartLoading(_ browser: CEFBrowser) {}
    func cefBrowserDidFinishLoading(_ browser: CEFBrowser) {}
    func cefBrowser(_ browser: CEFBrowser, didChangeTitle title: String) {}
    func cefBrowser(_ browser: CEFBrowser, didChangeURL url: URL) {}
    func cefBrowser(_ browser: CEFBrowser, didFailLoad error: Error) {}
}

/// A single CEF browser instance. Two embedding modes:
///   * `hostingWindow` — top-level NSWindow path. cmux glues it via
///     `parent.addChildWindow(_, ordered: .above)` + frame tracking.
///   * `embeddableView` — Path B: an NSView extracted from CEF's internal
///     `CefBrowserView`. The cmux pane controller `addSubview`s this into
///     a regular NSView container (NSSplitView, Bonsplit, etc.) just like
///     a WKWebView.
/// Exactly one of these is non-nil per browser.
///
/// Created via `CEFEngine.shared.makeBrowser(profile:initialURL:)` (legacy
/// child-window mode) or `CEFEngine.shared.makeEmbeddableBrowser(
/// profile:initialURL:)` (Path B, NSView embedding).
@MainActor
public final class CEFBrowser: NSObject {

    /// Non-nil when this browser was created via `makeBrowser` (top-level
    /// NSWindow / `addChildWindow` integration).
    public let hostingWindow: NSWindow?

    /// Non-nil when this browser was created via `makeEmbeddableBrowser`
    /// (NSView extracted from `CefBrowserView` so cmux can `addSubview` it
    /// directly into an existing NSView hierarchy).
    public let embeddableView: NSView?

    public weak var delegate: CEFBrowserDelegate?

    public var currentTitle: String? { bridge.currentTitle }
    public var currentURL: URL?      { bridge.currentURL }
    public var isLoading: Bool       { bridge.isLoading }
    public var canGoBack: Bool       { bridge.canGoBack }
    public var canGoForward: Bool    { bridge.canGoForward }

    private let bridge: CMUXCEFBrowserBridge

    init(bridge: CMUXCEFBrowserBridge) {
        self.bridge = bridge
        self.hostingWindow = bridge.hostingWindow
        self.embeddableView = bridge.embeddableView
        super.init()
        bridge.delegate = self
    }

    /// For embedded browsers: keep CEF's internal CefWindow at the same
    /// on-screen rectangle as the container hosting `embeddableView`.
    /// CEF clips its render canvas + computes mouse hit-test from the
    /// CefWindow frame, so the two must stay aligned. Call after any
    /// resize / divider drag / window move / screen change.
    public func syncRenderFrame(toScreen rect: NSRect) {
        bridge.syncRenderFrame(toScreenRect: rect)
    }

    /// Tell the bridge which cmux NSWindow this browser should be hosted
    /// on via `addChildWindow:`. Must be called before `syncRenderFrame`
    /// for the overlay to attach.
    public func attach(toHost window: NSWindow) {
        bridge.attach(toHostWindow: window)
    }

    /// Notify Chromium that the embedded view has been reparented / resized
    /// so it re-queries view size and pushes a fresh render layer.
    public func notifyEmbedHostResizedAndShown() {
        bridge.notifyEmbedHostResizedAndShown()
    }

    public func load(_ url: URL) { bridge.load(url) }
    public func goBack()         { bridge.goBack() }
    public func goForward()      { bridge.goForward() }
    public func reload()         { bridge.reload() }
    public func stopLoading()    { bridge.stopLoading() }
    public func showDevTools()   { bridge.showDevTools() }
    public func closeDevTools()  { bridge.closeDevTools() }
    public func close() {
        bridge.delegate = nil
        bridge.close()
    }
}

extension CEFBrowser: CMUXCEFBrowserBridgeDelegate {
    public nonisolated func browserBridgeDidStartLoading(_ bridge: CMUXCEFBrowserBridge) {
        MainActor.assumeIsolated {
            self.delegate?.cefBrowserDidStartLoading(self)
        }
    }

    public nonisolated func browserBridgeDidFinishLoading(_ bridge: CMUXCEFBrowserBridge) {
        MainActor.assumeIsolated {
            self.delegate?.cefBrowserDidFinishLoading(self)
        }
    }

    public nonisolated func browserBridge(
        _ bridge: CMUXCEFBrowserBridge,
        didChangeTitle title: String
    ) {
        MainActor.assumeIsolated {
            self.delegate?.cefBrowser(self, didChangeTitle: title)
        }
    }

    public nonisolated func browserBridge(
        _ bridge: CMUXCEFBrowserBridge,
        didChange url: URL
    ) {
        MainActor.assumeIsolated {
            self.delegate?.cefBrowser(self, didChangeURL: url)
        }
    }

    public nonisolated func browserBridge(
        _ bridge: CMUXCEFBrowserBridge,
        didFailLoad error: Error
    ) {
        MainActor.assumeIsolated {
            self.delegate?.cefBrowser(self, didFailLoad: error)
        }
    }
}

// MARK: - Engine factory

public extension CEFEngine {

    /// Create a new CEF browser inside its own borderless top-level
    /// `NSWindow`, using `profile`'s `CefRequestContext`.
    ///
    /// The returned browser's `hostingWindow` is created hidden. The
    /// caller (a cmux pane controller) is responsible for:
    ///   1. `parent.addChildWindow(browser.hostingWindow, ordered: .above)`
    ///   2. Tracking the pane placeholder's screen-space frame and calling
    ///      `browser.hostingWindow.setFrame(_:display:)` to follow it.
    ///   3. `browser.hostingWindow.orderFront(nil)` once positioned.
    ///   4. `orderOut` (not `close`) when the pane is hidden, so the
    ///      underlying CEF browser stays alive.
    ///   5. `browser.close()` exactly once when the pane is destroyed.
    func makeBrowser(
        profile: CEFProfile,
        initialURL: URL
    ) throws -> CEFBrowser {
        guard isRunning else {
            throw CEFEngineError.cefInitializeFailed(
                message: "CEFEngine.start has not been called yet")
        }
        let bridge: CMUXCEFBrowserBridge
        do {
            bridge = try CMUXCEFEngineBridge.shared().createBrowser(
                inProfile: profile.underlyingBridge,
                initialURL: initialURL)
        } catch {
            throw CEFEngineError.bridge(error as NSError)
        }
        return CEFBrowser(bridge: bridge)
    }

    /// Path B — create a browser whose underlying NSView can be embedded
    /// directly into a cmux NSView hierarchy (e.g., a Bonsplit pane or a
    /// vanilla NSSplitView). The returned `CEFBrowser` exposes the NSView
    /// via `embeddableView`. `hostingWindow` is `nil` in this mode.
    func makeEmbeddableBrowser(
        profile: CEFProfile,
        initialURL: URL
    ) throws -> CEFBrowser {
        guard isRunning else {
            throw CEFEngineError.cefInitializeFailed(
                message: "CEFEngine.start has not been called yet")
        }
        let bridge: CMUXCEFBrowserBridge
        do {
            bridge = try CMUXCEFEngineBridge.shared().createEmbeddableBrowser(
                inProfile: profile.underlyingBridge,
                initialURL: initialURL)
        } catch {
            throw CEFEngineError.bridge(error as NSError)
        }
        return CEFBrowser(bridge: bridge)
    }

    /// **Path C — Alloy runtime native NSView embedding.**
    ///
    /// Asks CEF to create the browser AS A SUBVIEW of `parentView` (via
    /// `CefWindowInfo::SetAsChild`). CEF 146 routes this through Alloy
    /// runtime automatically — no CefBrowserView, no CefWindow, no
    /// addChildWindow gymnastics. The CEF NSView behaves like any other
    /// AppKit subview.
    ///
    /// Use this when extension support is not required (Alloy in CEF 146
    /// does not expose the Chrome extension subsystem). Rendering, JS,
    /// network, devtools all remain full Chromium.
    func makeAlloyBrowser(
        parentView: NSView,
        bounds: NSRect,
        profile: CEFProfile,
        initialURL: URL
    ) throws -> CEFBrowser {
        guard isRunning else {
            throw CEFEngineError.cefInitializeFailed(
                message: "CEFEngine.start has not been called yet")
        }
        let bridge: CMUXCEFBrowserBridge
        do {
            bridge = try CMUXCEFEngineBridge.shared().createAlloyBrowser(
                withParentView: parentView,
                bounds: bounds,
                profile: profile.underlyingBridge,
                initialURL: initialURL)
        } catch {
            throw CEFEngineError.bridge(error as NSError)
        }
        return CEFBrowser(bridge: bridge)
    }
}
