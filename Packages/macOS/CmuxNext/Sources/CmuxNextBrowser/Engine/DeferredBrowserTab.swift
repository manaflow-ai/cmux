public import AppKit
public import Foundation
public import Observation

/// A browser tab whose page is not started yet: the address bar shows the
/// recorded URL and nothing loads until the user reloads (or navigates),
/// which asks the host (`onStart`) to replace it with a real page. Used
/// when cmux restarts after quitting unexpectedly twice in a row, so a page
/// that takes the app down cannot do it again on every launch.
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
    @ObservationIgnored public let contentView: NSView = NSView()
    @ObservationIgnored private var started = false

    public init(id: BrowserTabID, engine: BrowserEngineKind, profile: BrowserProfileID = .default, url: URL?, title: String?) {
        self.id = id
        self.engineKind = engine
        self.profileID = profile
        self.state = BrowserTabState(url: url, title: title)
    }

    private func start(_ url: URL?) {
        guard !started else { return }
        started = true
        onStart?(url)
    }

    public func load(_ url: URL) { start(url) }
    public func reload() { start(state.url) }
    public func goBack() {}
    public func goForward() {}
    public func stop() {}
    public func setFocused(_ focused: Bool) {}
    public func setContentVisible(_ visible: Bool) {}
    public func snapshot() async throws -> CGImage { throw BrowserTabError.snapshotUnavailable }
    public func evaluate(_ script: String, world: BrowserScriptWorld) async throws -> BrowserJSValue {
        throw BrowserTabError.closed
    }
    public func find(_ text: String, direction: BrowserFindDirection, caseSensitive: Bool) async -> BrowserFindResult { .none }
    public func clearFind() {}
    public func setZoom(_ zoom: Double) {}
    public func exitContentFullscreen() {}
    public func showDevTools() {}
    public func close() { started = true }
}
