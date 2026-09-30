import AppKit
import CmuxNextBridge
import CmuxNextBrowser
import CmuxNextDaemon
import CmuxNextTerminal
import Observation

/// Owns every terminal surface and browser page in the process
/// (architecture.md 4). Surfaces are keyed by tab, not by pane: a tab moved
/// to another pane keeps its surface and the destination pane reparents the
/// view (`SurfaceLedger`). Surfaces exist for presented tabs plus an LRU of 8
/// recently hidden ones; older hidden surfaces are destroyed and re-attach
/// from the daemon replay when shown. Previews of destroyed surfaces stay in
/// a 32 MB image LRU.
final class TabContentCache {
    private let daemon: DaemonService
    private var terminals: [String: TerminalEntry] = [:]
    private var browsers: [String: BrowserEntry] = [:]
    private var ledger = SurfaceLedger<String, ObjectIdentifier>(capacity: 8)
    private var presenters: [ObjectIdentifier: WeakPresenter] = [:]
    let previews = PreviewImageCache()
    let webKit = WebKitEngine()
    let cef = CEFEngine()
    private(set) var browserTabs: BrowserTabService!
    private var pendingBrowsers: Set<String> = []
    /// A CEF page finished its asynchronous creation; panes showing `key` re-show.
    var onBrowserReady: ((String) -> Void)?
    /// Presentation changed (for the blank-pane invariant).
    var onPresentationChange: (() -> Void)?
    weak var sessionDelegate: (any TerminalSessionDelegate)?

    init(daemon: DaemonService) {
        self.daemon = daemon
        browserTabs = BrowserTabService(daemon: daemon, cef: cef)
    }

    var liveTerminalCount: Int { terminals.count }

    /// True when `key` has a live surface or page (showing it is cheap).
    func hasContent(for key: String) -> Bool { terminals[key] != nil || browsers[key] != nil }

    func existingTerminal(_ key: String) -> TerminalEntry? { terminals[key] }

    // MARK: Terminals

    /// The surface for a daemon terminal tab, created (attached) on demand
    /// over `daemon`'s socket (the local daemon, or a Cloud machine's link).
    func terminal(for tab: TabModel, daemon: DaemonService) -> TerminalEntry {
        let validity = "\(daemon.machineID)#\(tab.id)#\(daemon.store.generation?.rawValue ?? "")#\(tab.surface.rawValue)"
        if let entry = terminals[tab.id], entry.validity == validity { return entry }
        if let stale = terminals.removeValue(forKey: tab.id) {
            // Daemon restarted or the tab's surface changed: the pane
            // presenting the old view lets it go before it closes.
            if let owner = ledger.remove(tab.id) { presenters[owner]?.value?.surfaceWasDisplaced(tab.id) }
            stale.close()
        }
        let target = DaemonTerminalIO.Target(
            attachment: TerminalAttachment.Target(surface: tab.surface, terminalResourceID: tab.terminalResourceID,
                                                  generation: daemon.store.generation),
            initialSize: tab.size ?? CellSize(cols: 80, rows: 24)
        )
        let io = DaemonTerminalIO(target: target, endpoint: { try await daemon.endpoint() })
        let session = TerminalSession(io: io, ownsGeometry: true)
        session.delegate = sessionDelegate
        let entry = TerminalEntry(validity: validity, session: session, io: io)
        terminals[tab.id] = entry
        // Paused until a visible pane presents it.
        let render = ledger.isRendering(tab.id)
        session.isRenderingSuspended = !render
        io.setVisible(render)
        return entry
    }

    /// The tab id whose surface is `session`.
    func tabKey(for session: TerminalSession) -> String? {
        terminals.first { $0.value.session === session }?.key
    }

    // MARK: Browsers

    func browser(for key: String, url: URL?) -> BrowserEntry {
        if let entry = browsers[key] { return entry }
        let tab = webKit.makeWebKitTab(BrowserTabConfiguration(id: BrowserTabID(rawValue: key), initialURL: url))
        let entry = BrowserEntry(tab: tab)
        browsers[key] = entry
        return entry
    }

    func existingBrowser(_ key: String) -> BrowserEntry? { browsers[key] }

    /// The page for a daemon browser tab on the engine its record names,
    /// written back to the record (url, title, favicon) while it lives.
    /// CEF starts lazily and creates tabs asynchronously: nil until ready.
    /// Falls back to WebKit when the CEF runtime is not bundled.
    func browser(for tab: TabModel) -> BrowserEntry? {
        let key = tab.id
        let url = tab.url.flatMap(URL.init(string:))
        guard tab.browserEngine == BrowserEngineTag.cef.rawValue, browserTabs.cefAvailable() else {
            let entry = browser(for: key, url: url)
            browserTabs.track(entry.tab, for: tab)
            return entry
        }
        if let entry = browsers[key] { return entry }
        guard pendingBrowsers.insert(key).inserted else { return nil }
        Task { [weak tab] in
            defer { pendingBrowsers.remove(key) }
            guard let page = try? await cef.makeTab(BrowserTabConfiguration(id: BrowserTabID(rawValue: key), initialURL: url)) else { return }
            browsers[key] = BrowserEntry(tab: page)
            if let tab { browserTabs.track(page, for: tab) }
            onBrowserReady?(key)
        }
        return nil
    }

    // MARK: Presentation and lifetime

    /// `presenter` shows `key` (its view is, or is about to be, in the
    /// presenter's hierarchy). Takes the surface from any previous presenter.
    func present(_ key: String, by presenter: any SurfacePresenter, visible: Bool) {
        let owner = ObjectIdentifier(presenter)
        presenters[owner] = WeakPresenter(value: presenter)
        apply(ledger.present(key, by: owner, ownerVisible: visible))
    }

    /// `presenter` stopped showing `key`. Ignored when another presenter
    /// took it meanwhile (the tab moved there).
    func withdraw(_ key: String, by presenter: any SurfacePresenter) {
        apply(ledger.withdraw(key, by: ObjectIdentifier(presenter)))
    }

    /// `presenter` scrolled on or off screen.
    func setVisible(_ visible: Bool, presenter: any SurfacePresenter) {
        apply(ledger.setVisible(visible, owner: ObjectIdentifier(presenter)))
    }

    /// `presenter` is going away.
    func removePresenter(_ presenter: any SurfacePresenter) {
        let owner = ObjectIdentifier(presenter)
        apply(ledger.removeOwner(owner))
        presenters[owner] = nil
    }

    /// The pane presenting `key`, if any.
    func presenter(of key: String) -> (any SurfacePresenter)? {
        ledger.owner(of: key).flatMap { presenters[$0]?.value }
    }

    func isRendering(_ key: String) -> Bool { ledger.isRendering(key) }

    private func apply(_ effects: SurfaceLedger<String, ObjectIdentifier>.Effects) {
        guard !effects.isEmpty else { return }
        for displaced in effects.displaced {
            presenters[displaced.owner]?.value?.surfaceWasDisplaced(displaced.key)
        }
        for (key, render) in effects.rendering { applyRendering(key, render) }
        for key in effects.evicted { terminals.removeValue(forKey: key)?.close() }
        presenters = presenters.filter { $0.value.value != nil }
        onPresentationChange?()
    }

    private func applyRendering(_ key: String, _ render: Bool) {
        if let entry = terminals[key] {
            entry.session.isRenderingSuspended = !render
            entry.io.setVisible(render)
            if !render {
                // Rendered off the main thread: the GPU readback used to block it.
                Task { [weak self] in
                    guard let image = await entry.session.snapshotInBackground(maxPixelSize: 480) else { return }
                    // The tab may have closed while the preview rendered.
                    guard let self, self.terminals[key] != nil else { return }
                    self.previews.insert(image, for: key)
                }
            }
        }
        if let entry = browsers[key] {
            Task { await entry.tab.setOccluded(!render) }
        }
    }

    /// The tab closed: free everything it held.
    func release(_ key: String) {
        if let owner = ledger.remove(key) { presenters[owner]?.value?.surfaceWasDisplaced(key) }
        terminals.removeValue(forKey: key)?.close()
        browsers.removeValue(forKey: key)?.close()
        browserTabs.untrack(key)
        previews.remove(key)
        onPresentationChange?()
    }

    /// Drops terminal surfaces whose tabs no longer exist.
    func prune(liveTabs: Set<String>) {
        for key in terminals.keys where !liveTabs.contains(key) { release(key) }
    }

    // MARK: Previews

    func previewImage(for key: String, maxPixelSize: CGSize) async -> CGImage? {
        if let entry = terminals[key],
           let image = await entry.session.snapshotInBackground(maxPixelSize: max(maxPixelSize.width, maxPixelSize.height)) {
            previews.insert(image, for: key)
            return image
        }
        if let entry = browsers[key], let image = try? await entry.tab.snapshot() {
            return image
        }
        return previews.image(for: key)
    }
}


/// A pane that shows cached content.
@MainActor
protocol SurfacePresenter: AnyObject {
    /// `key`'s view now belongs to another presenter, or its surface was
    /// destroyed. Drop the view if it is still installed here; do not
    /// withdraw or pause it.
    func surfaceWasDisplaced(_ key: String)
}

private struct WeakPresenter {
    weak var value: (any SurfacePresenter)?
}
