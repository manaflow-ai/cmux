import AppKit
import CmuxNextBridge
import CmuxNextBrowser
import CmuxNextDaemon
import CmuxNextTerminal
import Observation

/// Owns every terminal surface and browser page in the process
/// (architecture.md 4): surfaces exist for visible tabs plus an LRU of 8
/// recently hidden ones; older hidden surfaces are destroyed and re-attach
/// from the daemon replay when shown. Previews of destroyed surfaces stay in
/// a 32 MB image LRU.
final class TabContentCache {
    private let daemon: DaemonService
    private var terminals: [String: TerminalEntry] = [:]
    private var browsers: [String: BrowserEntry] = [:]
    private var retention = SurfaceRetention<String>(capacity: 8)
    let previews = PreviewImageCache()
    let webKit = WebKitEngine()
    let cef = CEFEngine()
    private(set) var browserTabs: BrowserTabService!
    private var pendingBrowsers: Set<String> = []
    /// A CEF page finished its asynchronous creation; panes showing `key` re-show.
    var onBrowserReady: ((String) -> Void)?
    weak var sessionDelegate: (any TerminalSessionDelegate)?

    init(daemon: DaemonService) {
        self.daemon = daemon
        browserTabs = BrowserTabService(daemon: daemon, cef: cef)
    }

    var liveTerminalCount: Int { terminals.count }

    // MARK: Terminals

    /// The surface for a daemon terminal tab, created (attached) on demand.
    func terminal(for tab: TabModel) -> TerminalEntry {
        let validity = "\(tab.id)#\(daemon.store.generation?.rawValue ?? "")#\(tab.surface.rawValue)"
        if let entry = terminals[tab.id], entry.validity == validity { return entry }
        terminals.removeValue(forKey: tab.id)?.close()
        let target = DaemonTerminalIO.Target(
            attachment: TerminalAttachment.Target(surface: tab.surface, terminalResourceID: tab.terminalResourceID,
                                                  generation: daemon.store.generation),
            initialSize: tab.size ?? CellSize(cols: 80, rows: 24)
        )
        let daemon = daemon
        let io = DaemonTerminalIO(target: target, endpoint: { try await daemon.endpoint() })
        let session = TerminalSession(io: io, ownsGeometry: true)
        session.delegate = sessionDelegate
        let entry = TerminalEntry(validity: validity, session: session, io: io)
        terminals[tab.id] = entry
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

    // MARK: Visibility and lifetime

    /// A tab's content was shown or hidden. Hiding may destroy the oldest
    /// hidden surfaces beyond the LRU.
    func setVisible(_ key: String, _ visible: Bool) {
        if let entry = terminals[key] {
            entry.session.isRenderingSuspended = !visible
            entry.io.setVisible(visible)
            if !visible, let image = entry.session.snapshot(maxPixelSize: 480) { previews.insert(image, for: key) }
        }
        if let entry = browsers[key] {
            Task { await entry.tab.setOccluded(!visible) }
        }
        for evicted in retention.setVisible(key, visible) {
            terminals.removeValue(forKey: evicted)?.close()
        }
    }

    /// The tab closed: free everything it held.
    func release(_ key: String) {
        retention.remove(key)
        terminals.removeValue(forKey: key)?.close()
        browsers.removeValue(forKey: key)?.close()
        browserTabs.untrack(key)
        previews.remove(key)
    }

    /// Drops terminal surfaces whose tabs no longer exist.
    func prune(liveTabs: Set<String>) {
        for key in terminals.keys where !liveTabs.contains(key) { release(key) }
    }

    // MARK: Previews

    func previewImage(for key: String, maxPixelSize: CGSize) async -> CGImage? {
        if let entry = terminals[key], let image = entry.session.snapshot(maxPixelSize: max(maxPixelSize.width, maxPixelSize.height)) {
            previews.insert(image, for: key)
            return image
        }
        if let entry = browsers[key], let image = try? await entry.tab.snapshot() {
            return image
        }
        return previews.image(for: key)
    }
}

