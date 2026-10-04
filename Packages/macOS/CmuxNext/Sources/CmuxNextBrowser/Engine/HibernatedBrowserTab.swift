public import AppKit
public import Foundation
public import Observation

/// Stands in for a page that hibernated (its engine page was closed to
/// free memory): keeps the URL, title, favicon and the last snapshot, and
/// shows the snapshot until the App restores the real page. Navigating or
/// reloading asks the host (`onWake`) to restore it first.
@Observable
public final class HibernatedBrowserTab: BrowserTab {
    public let id: BrowserTabID
    public let engineKind: BrowserEngineKind
    public let profileID: BrowserProfileID
    public let presentation: BrowserPresentation = .inView
    public private(set) var state: BrowserTabState
    public let favicon: NSImage?
    public let pendingPrompts: [BrowserPrompt] = []
    @ObservationIgnored public weak var delegate: (any BrowserTabDelegate)?
    @ObservationIgnored public weak var keyRouter: (any BrowserKeyRouting)?
    /// The saved history the real page is recreated with.
    public let restoreState: BrowserRestoreState
    /// The last page pixels, for the hover preview and the pane until the
    /// page is back.
    public let snapshotImage: CGImage?
    /// What woke the page, for the host to apply once it is restored.
    public enum Wake: Sendable, Hashable {
        case load(URL)
        case reload
        case goBack
        case goForward
    }

    /// Called when the user asks for the page (reload, navigate, history):
    /// the host restores it, then applies the request.
    @ObservationIgnored public var onWake: ((Wake) -> Void)?
    @ObservationIgnored public let contentView: NSView

    public init(id: BrowserTabID, engine: BrowserEngineKind, profile: BrowserProfileID, state: BrowserTabState,
                favicon: NSImage?, restoreState: BrowserRestoreState, snapshot: CGImage?) {
        self.id = id
        self.engineKind = engine
        self.profileID = profile
        var saved = BrowserTabState(url: state.url, title: state.title)
        saved.canGoBack = state.canGoBack
        saved.canGoForward = state.canGoForward
        saved.zoom = state.zoom
        self.state = saved
        self.favicon = favicon
        self.restoreState = restoreState
        self.snapshotImage = snapshot
        let view = NSImageView()
        view.imageScaling = .scaleAxesIndependently
        view.image = snapshot.map { NSImage(cgImage: $0, size: .zero) }
        view.wantsLayer = true
        contentView = view
    }

    public func load(_ url: URL) { onWake?(.load(url)) }
    public func reload() { onWake?(.reload) }
    public func goBack() { onWake?(.goBack) }
    public func goForward() { onWake?(.goForward) }
    public func stop() {}
    public func setFocused(_ focused: Bool) {}
    public func setContentVisible(_ visible: Bool) {}
    public func snapshot() async throws -> CGImage {
        guard let snapshotImage else { throw BrowserTabError.snapshotUnavailable }
        return snapshotImage
    }
    public func evaluate(_ script: String, world: BrowserScriptWorld) async throws -> BrowserJSValue {
        throw BrowserTabError.closed
    }
    public func find(_ text: String, direction: BrowserFindDirection, caseSensitive: Bool) async -> BrowserFindResult { .none }
    public func clearFind() {}
    public func setZoom(_ zoom: Double) {}
    public func exitContentFullscreen() {}
    public func showDevTools() {}
    public func close() {}
}
