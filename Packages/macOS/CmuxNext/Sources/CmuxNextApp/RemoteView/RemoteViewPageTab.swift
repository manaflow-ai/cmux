import AppKit
import CmuxNextBrowser
import CmuxNextRemoteView
import Foundation
import Observation

/// A `remote_view` tab (plans/cmux-next/remote-desktop.md 7): the browser
/// tab record `cmux://remote-view?host=…&target=…&mode=…` shown as the
/// native remote desktop pane, no engine (like `HistoryPageTab`). The
/// stream is never stored; the pane connects while it is visible and
/// pauses while hidden. Navigating it to a web address asks the host
/// (`onNavigate`) to turn the tab into a real page.
///
/// `RemoteViewTabPolicy` decides what it shows: a desktop only in
/// development builds, only for a loopback host, and only after a person
/// opened or confirmed the tab. Until the in-app transport lands only the
/// host `mock` streams; every other case shows `RemoteViewUnavailableView`.
@MainActor
@Observable
final class RemoteViewPageTab: BrowserTab {
    let id: BrowserTabID
    let engineKind: BrowserEngineKind
    let profileID: BrowserProfileID
    let presentation: BrowserPresentation = .inView
    private(set) var state: BrowserTabState
    let favicon: NSImage? = NSImage(systemSymbolName: "display", accessibilityDescription: nil)
    let pendingPrompts: [BrowserPrompt] = []
    @ObservationIgnored weak var delegate: (any BrowserTabDelegate)?
    @ObservationIgnored weak var keyRouter: (any BrowserKeyRouting)?
    @ObservationIgnored let record: RemoteViewTabRecord?
    @ObservationIgnored let contentView: NSView
    @ObservationIgnored var onNavigate: ((URL) -> Void)?
    @ObservationIgnored private let session: RemoteViewPageSession?

    /// `decision` is `RemoteViewTabPolicy`'s answer for the record at `url`.
    init(id: BrowserTabID, engine: BrowserEngineKind, profile: BrowserProfileID, url: URL, decision: RemoteViewTabDecision,
         closeTab: @escaping @MainActor () -> Void, connect: @escaping @MainActor (URL) -> Void) {
        self.id = id
        self.engineKind = engine
        self.profileID = profile
        let parsed: RemoteViewTabRecord? = switch decision {
        case let .connect(value), let .confirm(value): value
        case .unavailable: RemoteViewTabRecord(url: url)
        }
        record = parsed
        var state = BrowserTabState(url: url, title: RemoteViewTabRecord.tabTitle(parsed))
        state.phase = .finished
        self.state = state
        switch decision {
        case let .connect(record):
            let session = RemoteViewPageSession.make(record: record, closeTab: closeTab)
            self.session = session
            contentView = session?.view ?? RemoteViewUnavailableView(content: .unavailable(.noTransport(host: record.host)))
        case let .confirm(record):
            session = nil
            let notice = RemoteViewUnavailableView(content: .confirm(host: record.host))
            // Connect starts view mode; control is the toolbar toggle.
            notice.onConnect = { connect(record.url) }
            contentView = notice
        case let .unavailable(reason):
            session = nil
            contentView = RemoteViewUnavailableView(content: .unavailable(reason))
        }
    }

    func load(_ url: URL) {
        if RemoteViewTabRecord.matches(url) { return }
        onNavigate?(url)
    }

    /// Reload never reconnects: after Stop only the pane's Reconnect (a
    /// person) starts a new session, never `browser reload` automation.
    func reload() {}
    func goBack() {}
    func goForward() {}
    func stop() { session?.pause() }

    func setFocused(_ focused: Bool) {
        guard focused, let window = contentView.window else { return }
        window.makeFirstResponder(session?.focusTarget ?? contentView)
    }

    func setContentVisible(_ visible: Bool) {
        contentView.isHidden = !visible
        if visible { session?.resume() } else { session?.pause() }
    }

    func snapshot() async throws -> CGImage {
        guard let rep = contentView.bitmapImageRepForCachingDisplay(in: contentView.bounds) else { throw BrowserTabError.snapshotUnavailable }
        contentView.cacheDisplay(in: contentView.bounds, to: rep)
        guard let image = rep.cgImage else { throw BrowserTabError.snapshotUnavailable }
        return image
    }

    func evaluate(_ script: String, world: BrowserScriptWorld) async throws -> BrowserJSValue { throw BrowserTabError.closed }
    func find(_ text: String, direction: BrowserFindDirection, caseSensitive: Bool) async -> BrowserFindResult { .none }
    func clearFind() {}
    func setZoom(_ zoom: Double) {}
    func exitContentFullscreen() {}
    func showDevTools() {}
    func close() { session?.pause() }
}
