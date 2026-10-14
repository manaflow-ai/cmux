public import AppKit
public import CmuxNextBrowser
public import Observation
import SwiftUI

/// A Mac Screen tab (`cmux://mac-screen…`, `MacScreenRecord`) shown as a
/// native page, no engine (like the remote view and history pages): the
/// home page, or one paired Mac's screen (`MacScreenPane`). Navigating it to
/// a web address asks the owner (`onNavigate`) to make it a real page.
@MainActor
@Observable
public final class MacScreenPageTab: BrowserTab {
    public let id: BrowserTabID
    public let engineKind: BrowserEngineKind
    public let profileID: BrowserProfileID
    public let presentation: BrowserPresentation = .inView
    public private(set) var state: BrowserTabState
    public let favicon: NSImage? = NSImage(systemSymbolName: "display", accessibilityDescription: nil)
    public let pendingPrompts: [BrowserPrompt] = []
    @ObservationIgnored public weak var delegate: (any BrowserTabDelegate)?
    @ObservationIgnored public weak var keyRouter: (any BrowserKeyRouting)?
    @ObservationIgnored public let record: MacScreenRecord
    @ObservationIgnored public let contentView: NSView
    @ObservationIgnored public var onNavigate: ((URL) -> Void)?
    /// Shows another Mac Screen record in this tab (never a web page).
    @ObservationIgnored public var onShowRecord: ((URL) -> Void)?
    /// The screen; nil for the home page, and until the saved Macs are read.
    @ObservationIgnored public private(set) var pane: MacScreenPane?
    @ObservationIgnored private var visible = false
    @ObservationIgnored private var focused = false

    /// The home page.
    public init(id: BrowserTabID, engine: BrowserEngineKind, profile: BrowserProfileID, home: NSView) {
        self.id = id
        engineKind = engine
        profileID = profile
        record = MacScreenRecord(macID: nil)
        pane = nil
        contentView = home
        state = Self.state(url: record.url, title: L.t("macScreen.tab.homeTitle", "Mac Screen"))
        #if DEBUG
        Self.live.add(self)
        #endif
    }

    /// One paired Mac's screen; `install(_:)` puts it in once the saved Macs are read.
    public init(id: BrowserTabID, engine: BrowserEngineKind, profile: BrowserProfileID, record: MacScreenRecord) {
        self.id = id
        engineKind = engine
        profileID = profile
        self.record = record
        pane = nil
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.cgColor
        contentView = container
        state = Self.state(url: record.url, title: L.t("macScreen.tab.homeTitle", "Mac Screen"))
        #if DEBUG
        Self.live.add(self)
        #endif
    }

    /// The saved Mac was renamed.
    func rename(_ name: String) {
        pane?.model.name = name
        state.title = name
    }

    /// Shows `pane` in this tab (once).
    public func install(_ pane: MacScreenPane) {
        guard self.pane == nil else { return }
        self.pane = pane
        pane.view.frame = contentView.bounds
        pane.view.autoresizingMask = [.width, .height]
        contentView.addSubview(pane.view)
        state.title = pane.model.name
        if visible { pane.resume() }
        if focused { setFocused(true) }
    }

    private static func state(url: URL, title: String) -> BrowserTabState {
        var state = BrowserTabState(url: url, title: title)
        state.phase = .finished
        return state
    }

    #if DEBUG
    /// Every live Mac Screen tab, for `debug.mac_screen` (weak).
    public static let live = NSHashTable<MacScreenPageTab>.weakObjects()
    #endif

    public func load(_ url: URL) {
        if MacScreenRecord.matches(url) {
            if MacScreenRecord(url: url) != record { onShowRecord?(url) }
            return
        }
        onNavigate?(url)
    }

    /// Reload is Refresh Screen; it never reconnects a stopped session.
    public func reload() { pane?.session?.refresh() }
    public func goBack() {}
    public func goForward() {}
    public func stop() {}

    public func setFocused(_ focused: Bool) {
        self.focused = focused
        guard focused, let window = contentView.window else { return }
        window.makeFirstResponder(pane?.focusTarget ?? contentView)
    }

    public func setContentVisible(_ visible: Bool) {
        // The view stays in the hierarchy like a web tab's (the cache shows only the
        // selected tab); hiding it would collapse the chrome of a tab restored hidden.
        self.visible = visible
        if visible { pane?.resume() } else { pane?.pause() }
    }

    public func snapshot() async throws -> CGImage {
        guard let rep = contentView.bitmapImageRepForCachingDisplay(in: contentView.bounds) else { throw BrowserTabError.snapshotUnavailable }
        contentView.cacheDisplay(in: contentView.bounds, to: rep)
        guard let image = rep.cgImage else { throw BrowserTabError.snapshotUnavailable }
        return image
    }

    public func evaluate(_ script: String, world: BrowserScriptWorld) async throws -> BrowserJSValue { throw BrowserTabError.closed }
    public func find(_ text: String, direction: BrowserFindDirection, caseSensitive: Bool) async -> BrowserFindResult { .none }
    public func clearFind() {}
    public func setZoom(_ zoom: Double) {}
    public func exitContentFullscreen() {}
    public func showDevTools() {}
    public func close() { pane?.close() }
}
