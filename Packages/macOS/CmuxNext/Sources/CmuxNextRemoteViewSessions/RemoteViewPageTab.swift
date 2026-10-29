public import AppKit
public import CmuxNextBrowser
public import CmuxNextWakeups
import CmuxNextIcons
public import CmuxNextRemoteView
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
public final class RemoteViewPageTab: BrowserTab {
    public let id: BrowserTabID
    public let engineKind: BrowserEngineKind
    public let profileID: BrowserProfileID
    public let presentation: BrowserPresentation = .inView
    public private(set) var state: BrowserTabState
    public let favicon: NSImage? = NSImage.icon(.remoteDisplay, size: 16)
    public let pendingPrompts: [BrowserPrompt] = []
    @ObservationIgnored public weak var delegate: (any BrowserTabDelegate)?
    @ObservationIgnored public weak var keyRouter: (any BrowserKeyRouting)?
    @ObservationIgnored public let record: RemoteViewTabRecord?
    @ObservationIgnored public let contentView: NSView
    @ObservationIgnored public var onNavigate: ((URL) -> Void)?
    /// The record this tab was built from: a discard builds it again from there (`BrowserStreamedPage`).
    @ObservationIgnored private let address: URL
    @ObservationIgnored private let session: RemoteViewPageSession?
    /// A woken tab's last frame until the stream presents its first one.
    @ObservationIgnored private let wakeCover = BrowserWakeCover()

    /// `decision` is `RemoteViewTabPolicy`'s answer for the record at `url`; `work`, `mainWork` and `vncSignIns` are
    /// the app's (a VNC sign-in comes from memory, or a Keychain read on the system lane that answers on main
    /// through the scheduler); `cloudTransport` reaches a Cloud machine's desktop over the app's Cloud tunnel.
    public init(id: BrowserTabID, engine: BrowserEngineKind, profile: BrowserProfileID, url: URL, decision: RemoteViewTabDecision,
         work: BackgroundWork, mainWork: MainWorkScheduler, vncSignIns: RemoteVNCSignIns, closeTab: @escaping @MainActor () -> Void,
         connect: @escaping @MainActor (URL) -> Void,
         cloudTransport: RemoteViewPageSession.CloudDesktopTransport? = nil,
         cloudRd: RemoteViewPageSession.CloudRdTransport? = nil, displayName: String? = nil) {
        self.id = id
        self.engineKind = engine
        self.profileID = profile
        let parsed: RemoteViewTabRecord? = switch decision {
        case let .connect(value), let .confirm(value): value
        case .unavailable: RemoteViewTabRecord(url: url)
        }
        record = parsed
        address = url
        // A Cloud machine's tab and pane read its name, not its id.
        var state = BrowserTabState(url: url, title: displayName ?? RemoteViewTabRecord.tabTitle(parsed))
        state.phase = .finished
        self.state = state
        switch decision {
        case let .connect(record):
            let session = RemoteViewPageSession.make(record: record, work: work, mainWork: mainWork, vncSignIns: vncSignIns, closeTab: closeTab,
                                                     cloudTransport: cloudTransport, cloudRd: cloudRd, displayName: displayName)
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
        session?.onOwnContent = { [weak self] in self?.wakeCover.remove() }
        #if DEBUG
        Self.live.add(self)
        #endif
    }

    #if DEBUG
    /// Every live remote view tab, for `debug.remote_view` (weak).
    // singleton-allow: a DEBUG-only weak registry the debug socket method reads; moved from CmuxNextApp as is, only public for the move.
    public static let live = NSHashTable<RemoteViewPageTab>.weakObjects()

    /// The Connect button of a tab that asks first; nil for any other tab.
    public var debugConnect: (() -> Void)? { (contentView as? RemoteViewUnavailableView)?.onConnect }

    /// The tab's session, when it streams (development path or mock).
    public var debugSession: RemoteViewPageSession? { session }
    #endif

    /// The windows' frame-aligned pointer input for the desktop pane (feature `pointerFrameRemoteInput`);
    /// a tab with no session has none.
    public var pointerFrames: FrameInputCoalescers? {
        get { session?.pointerFrames }
        set { session?.pointerFrames = newValue }
    }

    public func load(_ url: URL) {
        if RemoteViewTabRecord.matches(url) { return }
        onNavigate?(url)
    }

    /// Reload never reconnects: after Stop only the pane's Reconnect (a
    /// person) starts a new session, never `browser reload` automation.
    public func reload() {}
    public func goBack() {}
    public func goForward() {}
    public func stop() { session?.pause() }

    public func setFocused(_ focused: Bool) {
        guard focused, let window = contentView.window else { return }
        window.makeFirstResponder(session?.focusTarget ?? contentView)
    }

    public func setContentVisible(_ visible: Bool) {
        contentView.isHidden = !visible
        if visible { session?.resume() } else { session?.pause() }
    }

    /// The pane as drawn, with the stream's last frame in its video (a video layer is not drawn by
    /// `cacheDisplay`); a tab with no frame, or whose pane shows a card, as drawn.
    public func snapshot() async throws -> CGImage {
        if let picture = await session?.picture() { return picture }
        guard let rep = contentView.bitmapImageRepForCachingDisplay(in: contentView.bounds) else { throw BrowserTabError.snapshotUnavailable }
        contentView.cacheDisplay(in: contentView.bounds, to: rep)
        guard let image = rep.cgImage else { throw BrowserTabError.snapshotUnavailable }
        return image
    }

    public func evaluate(_ script: String, world: BrowserScriptWorld, gesture: BrowserScriptGesture) async throws -> BrowserJSValue { throw BrowserTabError.closed }
    public func find(_ text: String, direction: BrowserFindDirection, caseSensitive: Bool) async -> BrowserFindResult { .none }
    public func clearFind() {}
    public func setZoom(_ zoom: Double) {}
    public func exitContentFullscreen() {}
    public func showDevTools() {}
    public func close() {
        wakeCover.remove()
        session?.end()
    }
}

extension RemoteViewPageTab: BrowserStreamedPage {
    /// Its record, which a shown tab connects from as this one does; never while the person's Stop
    /// or the host ended the session: only the pane's Reconnect (a person) starts a new one.
    public var wakeAddress: URL? {
        session?.isEnded == true ? nil : address
    }

    /// Covers a streaming tab with its last frame until the new stream presents its first frame,
    /// or the pane shows why the session ended.
    @discardableResult
    public func showStandIn(_ picture: CGImage, decoded: Bool, cap: Duration, clock: any Clock<Duration>) -> Bool {
        guard session != nil else { return false }
        wakeCover.show(picture, decoded: decoded, in: contentView, cap: cap, clock: clock)
        return true
    }

    public var wakeCoverCap: Duration? { BrowserWakeCover.reconnectCap }

    /// The pixels the last frame's cover draws now; nil while none covers the tab (tests, debug).
    public var wakeCoverPixels: CGImage? { wakeCover.shownPixels }

    /// The last frame covers the page now (tests, debug).
    public var showsWakeCover: Bool { wakeCover.isShown }
}
