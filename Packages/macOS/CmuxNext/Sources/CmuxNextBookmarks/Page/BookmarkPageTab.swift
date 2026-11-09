public import AppKit
public import CmuxNextBrowser
import CmuxNextIcons
public import CmuxNextPages
import CmuxNextSettings
public import Foundation
public import Observation

/// The `cmux://bookmarks` manager in a browser tab: the React page
/// (``PageDescriptor/bookmarks``) on the shared page host, no engine of its own. Navigating it
/// to a web address asks the host (`onNavigate`) to turn the tab into a real page.
@MainActor
@Observable
public final class BookmarkPageTab: BrowserTab {
    public let id: BrowserTabID
    public let engineKind: BrowserEngineKind
    public let profileID: BrowserProfileID
    public let presentation: BrowserPresentation = .inView
    public private(set) var state: BrowserTabState
    public let favicon: NSImage? = NSImage.icon(.bookmarkManager, size: 16)
    public let pendingPrompts: [BrowserPrompt] = []
    @ObservationIgnored public weak var delegate: (any BrowserTabDelegate)?
    @ObservationIgnored public weak var keyRouter: (any BrowserKeyRouting)?
    /// The page, nil only when the page resources are missing (the tab stays blank).
    @ObservationIgnored public let webPage: PageWebView?
    @ObservationIgnored public let host: BookmarkPageHostProvider
    @ObservationIgnored public let contentView: NSView
    @ObservationIgnored public var onNavigate: ((URL) -> Void)?

    public init(id: BrowserTabID, engine: BrowserEngineKind, profile: BrowserProfileID, host: BookmarkPageHostProvider,
         webPage: PageWebView?) {
        self.id = id
        self.engineKind = engine
        self.profileID = profile
        var state = BrowserTabState(url: .bookmarkPage, title: BookmarkStrings.pageTitle)
        state.phase = .finished
        self.state = state
        self.host = host
        self.webPage = webPage
        contentView = webPage ?? NSView()
    }

    /// Shows bookmark `id`: its folder, with it selected.
    public func reveal(_ id: String) {
        webPage?.send(command: BookmarkPageHostProvider.revealCommand, arguments: ["bookmark": .string(id)])
    }

    public func load(_ url: URL) {
        if url.isBookmarkPage { return reload() }
        onNavigate?(url)
    }

    public func reload() { webPage?.reload() }
    public func goBack() {}
    public func goForward() {}
    public func stop() {}

    public func setFocused(_ focused: Bool) {
        guard focused, contentView.window != nil else { return }
        webPage?.focusPage()
    }

    public func setContentVisible(_ visible: Bool) {
        contentView.isHidden = !visible
        // The page stays current from the daemon's change events; a top page may have changed profile.
        if visible { host.pageShown() }
    }

    public func snapshot() async throws -> CGImage {
        guard let rep = contentView.bitmapImageRepForCachingDisplay(in: contentView.bounds) else { throw BrowserTabError.snapshotUnavailable }
        contentView.cacheDisplay(in: contentView.bounds, to: rep)
        guard let image = rep.cgImage else { throw BrowserTabError.snapshotUnavailable }
        return image
    }

    public func evaluate(_ script: String, world: BrowserScriptWorld, gesture: BrowserScriptGesture) async throws -> BrowserJSValue { throw BrowserTabError.closed }
    public func find(_ text: String, direction: BrowserFindDirection, caseSensitive: Bool) async -> BrowserFindResult {
        webPage?.send(command: "find", arguments: ["text": .string(text)])
        return .none
    }
    public func clearFind() {}
    public func setZoom(_ zoom: Double) {}
    public func exitContentFullscreen() {}
    public func showDevTools() {}
    public func close() { webPage?.close() }
}
