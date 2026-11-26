public import AppKit
public import Foundation
public import Observation

/// A browser tab whose page is not started yet: the address bar shows the
/// recorded URL and nothing loads until the user reloads (or navigates),
/// which asks the host (`onStart`) to replace it with a real page. Used for
/// a page that was loading when cmux quit unexpectedly twice in a row (so it
/// cannot take the app down on every launch), for a Chromium tab while
/// Chromium cannot start, and for a restored Chromium tab while its page is
/// made. It shows the page background, as Chrome does while it loads a tab
/// restored after a relaunch, never a picture of the run before (cmux#57419).
@Observable
public final class DeferredBrowserTab: BrowserTab {
    public let id: BrowserTabID
    public let engineKind: BrowserEngineKind
    public let profileID: BrowserProfileID
    public let presentation: BrowserPresentation = .inView
    public private(set) var state: BrowserTabState
    public let favicon: NSImage? = nil
    public let pendingPrompts: [BrowserPrompt] = []
    @ObservationIgnored public weak var delegate: (any BrowserTabDelegate)?
    @ObservationIgnored public weak var keyRouter: (any BrowserKeyRouting)?
    /// Called once, with the URL to open, when the user asks for the page.
    @ObservationIgnored public var onStart: ((URL?) -> Void)?
    @ObservationIgnored public let contentView = NSView()
    /// It stands in for a restored tab's page while the page is made (`handOver(to:)`): not a page to drive yet.
    public let restoresPage: Bool
    /// The address the user asked for before the page took over (`.some(nil)`: a reload); nil when none.
    @ObservationIgnored public private(set) var startRequest: URL??
    @ObservationIgnored private var started = false

    public init(id: BrowserTabID, engine: BrowserEngineKind, profile: BrowserProfileID = .default, url: URL?, title: String?,
                restoresPage: Bool = false) {
        self.restoresPage = restoresPage
        self.id = id
        self.engineKind = engine
        self.profileID = profile
        self.state = BrowserTabState(url: url, title: title)
    }

    private func start(_ url: URL?) {
        guard !started else { return }
        started = true
        startRequest = .some(url)
        onStart?(url)
    }

    /// The restored tab's page is here: a load or reload the user asked for meanwhile runs on it. Call after the page
    /// replaced this one.
    public func handOver(to page: any BrowserTab) {
        switch startRequest {
        case .some(.some(let url)): page.load(url)
        case .some(.none): page.reload()
        case nil: break
        }
    }

    public func load(_ url: URL) { start(url) }
    public func reload() { start(state.url) }
    public func goBack() {}
    public func goForward() {}
    public func stop() {}
    public func setFocused(_ focused: Bool) {}
    public func setContentVisible(_ visible: Bool) {}
    public func snapshot() async throws -> CGImage { throw BrowserTabError.snapshotUnavailable }
    public func evaluate(_ script: String, world: BrowserScriptWorld, gesture: BrowserScriptGesture) async throws -> BrowserJSValue {
        throw BrowserTabError.closed
    }
    public func find(_ text: String, direction: BrowserFindDirection, caseSensitive: Bool) async -> BrowserFindResult { .none }
    public func clearFind() {}
    public func setZoom(_ zoom: Double) {}
    public func exitContentFullscreen() {}
    public func showDevTools() {}
    public func close() { started = true }
}
