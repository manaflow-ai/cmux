public import Foundation

/// A browser engine. One instance per engine kind per process.
///
/// `makeTab` is async because CEF initializes lazily on its first tab.
public protocol BrowserEngine: AnyObject, Sendable {
    var kind: BrowserEngineKind { get }
    var availability: BrowserEngineAvailability { get }
    var capabilities: BrowserCapabilities { get }
    func makeTab(_ configuration: BrowserTabConfiguration) async throws -> any BrowserTab
}

/// Everything needed to create a tab.
public nonisolated struct BrowserTabConfiguration: Hashable, Sendable {
    public var id: BrowserTabID
    public var profile: BrowserProfileID
    /// Loaded right after creation. nil leaves the tab blank.
    public var initialURL: URL?
    /// Starting zoom, e.g. a per-site zoom the App layer remembers.
    public var zoom: Double
    /// The pane that shows the tab. Engines that group tabs per pane (CEF:
    /// one Chromium window per pane) use it; nil gives the tab its own group.
    public var pane: BrowserPaneID?
    /// History to restore instead of loading `initialURL` fresh (a tab
    /// waking from hibernation). `initialURL` is the fallback when the
    /// engine cannot restore it.
    public var restoreState: BrowserRestoreState?
    /// The remote-localhost derived store, nil for the profile's own store
    /// (plans/cmux-next/remote-localhost.md section 3).
    public var machineStore: BrowserMachineStore?
    /// Main-frame navigations this tab's store may hold.
    public var navigationGuard: BrowserNavigationGuard

    public init(
        id: BrowserTabID = .random(),
        profile: BrowserProfileID = .default,
        initialURL: URL? = nil,
        zoom: Double = 1,
        pane: BrowserPaneID? = nil,
        machineStore: BrowserMachineStore? = nil,
        navigationGuard: BrowserNavigationGuard = .none
    ) {
        self.id = id
        self.profile = profile
        self.initialURL = initialURL
        self.zoom = zoom
        self.pane = pane
        self.machineStore = machineStore
        self.navigationGuard = navigationGuard
    }
}

/// A page's back/forward history with page state (scroll position, form
/// data), saved when the page hibernates and restored when it wakes.
public nonisolated enum BrowserRestoreState: Hashable, Sendable {
    /// `WKWebView.interactionState`, archived.
    case webKit(Data)
    /// The Chromium fork's `cmux_tab_navigation_state` (API 7).
    case chromium(String)
}
