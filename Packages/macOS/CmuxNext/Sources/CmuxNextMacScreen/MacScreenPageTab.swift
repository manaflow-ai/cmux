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
    /// The screen; nil for the home page.
    @ObservationIgnored public let pane: MacScreenPane?

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

    /// One paired Mac's screen.
    public init(id: BrowserTabID, engine: BrowserEngineKind, profile: BrowserProfileID, record: MacScreenRecord, pane: MacScreenPane) {
        self.id = id
        engineKind = engine
        profileID = profile
        self.record = record
        self.pane = pane
        contentView = pane.view
        state = Self.state(url: record.url, title: pane.model.name)
        #if DEBUG
        Self.live.add(self)
        #endif
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
        if MacScreenRecord.matches(url), MacScreenRecord(url: url) == record { return }
        onNavigate?(url)
    }

    /// Reload is Refresh Screen; it never reconnects a stopped session.
    public func reload() { pane?.session?.refresh() }
    public func goBack() {}
    public func goForward() {}
    public func stop() {}

    public func setFocused(_ focused: Bool) {
        guard focused, let window = contentView.window else { return }
        window.makeFirstResponder(pane?.focusTarget ?? contentView)
    }

    public func setContentVisible(_ visible: Bool) {
        contentView.isHidden = !visible
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
