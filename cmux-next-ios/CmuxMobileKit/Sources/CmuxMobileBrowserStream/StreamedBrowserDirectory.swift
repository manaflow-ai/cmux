import CmuxMobileTransport
import Foundation
import os

private let log = Logger(subsystem: "dev.cmux.mobile", category: "browser-stream")

/// Streamed browser tabs while the app is linked to a Mac: one model per tab
/// key, kept while the tab exists so the page and its history stay on the
/// Mac across tab switches and link drops. The live coordinator sets
/// ``opener`` (the current link) and calls ``linkChanged()``; with no opener
/// browser tabs stay local web views.
@MainActor
public final class StreamedBrowserDirectory {
    public static let shared = StreamedBrowserDirectory()

    /// The current link when it can stream browser tabs, else nil.
    public var opener: (@Sendable () async -> (any BrowserStreamOpening)?)? {
        didSet { if opener == nil, macOpener == nil { reset() } else if appActive { localhost.resume() } }
    }
    /// The link of a given Mac (the phone links several at once): a tab named
    /// with its Mac streams over that Mac's link only, never the focused one.
    public var macOpener: (@Sendable (_ macID: String) async -> (any BrowserStreamOpening)?)? {
        didSet { if opener == nil, macOpener == nil { reset() } else if appActive { localhost.resume() } }
    }

    /// A tab's model key: tab ids (`s<surface>`) repeat across Macs.
    static func key(tab: String, macID: String?) -> String {
        guard let macID, !macID.isEmpty else { return tab }
        return "\(macID)\u{1}\(tab)"
    }

    /// The tab id and Mac of a model key.
    static func parts(_ key: String) -> (tab: String, macID: String?) {
        let pieces = key.split(separator: "\u{1}", maxSplits: 1).map(String.init)
        return pieces.count == 2 ? (pieces[1], pieces[0]) : (key, nil)
    }

    private var models: [String: StreamedBrowserModel] = [:]
    private var lastWarm: ContinuousClock.Instant?
    private var appActive = true

    public init() {}

    public var isLive: Bool { opener != nil || macOpener != nil }

    /// Native browser tabs' `localhost:<port>` pages, forwarded to their Mac's loopback.
    public private(set) lazy var localhost = LocalhostForwarder { [weak self] macID, port in
        guard let link = await self?.link(macID: macID) else {
            throw LinkError(code: "no-link", message: "Not connected to the Mac")
        }
        return try await link.openLocalhost(port: port)
    }

    /// A Mac's link (`macID`: its own; nil: the focused Mac's), or nil when not linked.
    func link(macID: String?) async -> (any BrowserStreamOpening)? {
        if let macID, !macID.isEmpty, let macOpener { return await macOpener(macID) }
        return await opener?()
    }

    /// Hears the tabs the Macs list (``retain(tabs:)``) and placeholder tabs that
    /// became real (``rename(tab:to:)``): pages opened on the iPhone follow them.
    public var tabsRetained: (@MainActor (Set<String>) -> Void)?
    public var tabRenamed: (@MainActor (_ old: String, _ new: String) -> Void)?

    /// The streamed model of a tab (`tab`: its key on the Mac, `url`: its
    /// first page), or nil when not linked.
    public func model(tab: String, url: URL?, macID: String? = nil) -> StreamedBrowserModel? {
        let macID = macOpener == nil ? nil : macID.flatMap { $0.isEmpty ? nil : $0 }
        guard macID != nil || opener != nil else { return nil }
        let key = Self.key(tab: tab, macID: macID)
        if let model = models[key] {
            warmMedia()
            return model
        }
        let model = StreamedBrowserModel(tab: tab, url: url) { [weak self] sink, tab, current in
            // The link up now (a stream reopens on a new link): the tab's own Mac's when known.
            let link: (any BrowserStreamOpening)?
            if let macID {
                link = await self?.macOpener?(macID)
            } else {
                link = await self?.opener?()
            }
            guard let link else { throw LinkError(code: "no-link", message: "Not connected to the Mac") }
            return try await link.openBrowser(tab: tab, url: (current ?? url)?.absoluteString, sink: sink)
        }
        model.openedHidden = { [weak self] in
            guard let self else { return }
            for shown in models.values where shown.isShown { shown.reassertShown() }
        }
        models[key] = model
        if !appActive { model.setAppActive(false) }
        warmMedia()
        return model
    }

    /// The streamed model of a Mac phone tab's simulator (`tab`: `s<surface>`), or nil
    /// when not linked. It is a browser tab's stream (one media lane, the shown tab
    /// owns it) with no page: the simulator page reads ``StreamedBrowserModel/meter``,
    /// ``StreamedBrowserModel/phase`` and sends touches at 0...1 of its screen.
    public func simulatorModel(tab: String, macID: String? = nil) -> StreamedBrowserModel? {
        let macID = macOpener == nil ? nil : macID.flatMap { $0.isEmpty ? nil : $0 }
        guard macID != nil || opener != nil else { return nil }
        let key = Self.key(tab: tab, macID: macID)
        if let model = models[key] { return model }
        let model = StreamedBrowserModel(tab: tab, url: nil) { [weak self] sink, tab, _ in
            let link: (any BrowserStreamOpening)?
            if let macID {
                link = await self?.macOpener?(macID)
            } else {
                link = await self?.opener?()
            }
            guard let link else { throw LinkError(code: "no-link", message: "Not connected to the Mac") }
            return try await link.openSurface(tab: tab, sink: sink)
        }
        model.openedHidden = { [weak self] in
            guard let self else { return }
            for shown in models.values where shown.isShown { shown.reassertShown() }
        }
        models[key] = model
        if !appActive { model.setAppActive(false) }
        warmMedia()
        return model
    }

    /// A workspace with browser tabs is shown: the WebRTC media session
    /// beside a WireGuard link opens before the first tab needs it.
    private func warmMedia() {
        // A warm-up lasts a minute on the link; at most one ask per 20 s.
        let now = ContinuousClock.now
        if let lastWarm, now - lastWarm < .seconds(20) { return }
        lastWarm = now
        guard let opener else { return }
        // task-owner: fire and forget; the link ignores it without a media session
        Task { await opener()?.warmMedia() }
    }

    /// A new workspace's placeholder tab became the Mac's real tab: the
    /// phone finds its page under the real id. The page keeps its Mac host's
    /// key (the placeholder's), so a redial reopens this page, history and
    /// all, not a new blank host for the real id.
    public func rename(tab old: String, to new: String) {
        tabRenamed?(old, new)
        let renamed = models.keys.filter { Self.parts($0).tab == old }
        guard old != new, !renamed.isEmpty else {
            log.notice("browser rename \(old, privacy: .public) -> \(new, privacy: .public): no model")
            return
        }
        log.notice("browser rename \(old, privacy: .public) -> \(new, privacy: .public)")
        for key in renamed {
            guard let model = models.removeValue(forKey: key) else { continue }
            let next = Self.key(tab: new, macID: Self.parts(key).macID)
            models.removeValue(forKey: next)?.close()
            models[next] = model
        }
    }

    /// The tab closed on the phone (`macID`: its Mac; nil: the tab on any Mac).
    public func drop(tab: String, macID: String? = nil) {
        for key in models.keys where Self.parts(key).tab == tab && (macID == nil || Self.parts(key).macID == nil || Self.parts(key).macID == macID) {
            log.notice("browser drop \(tab, privacy: .public)")
            models.removeValue(forKey: key)?.close()
        }
    }

    /// The tabs the Macs list now (every workspace's, and this phone's
    /// pending ones): a tab whose workspace closed on the Mac is dropped, so
    /// a redial never opens it again (transport-verify-20261019.md defect 7).
    public func retain(tabs: Set<String>) {
        tabsRetained?(tabs)
        for key in models.keys where !tabs.contains(Self.parts(key).tab) {
            log.notice("browser drop \(key, privacy: .public)")
            models.removeValue(forKey: key)?.close()
        }
    }

    /// A new link (`macID`: that Mac's; nil: any): the shown tab's stream
    /// comes back. Hidden tabs open when they are shown again: each open
    /// claims the link's one media lane and a Mac host, so reopening every
    /// tab the phone holds gave the lane to a hidden one and made the Mac
    /// stop the shown tab's page (defect 7).
    public func linkChanged(macID: String? = nil) {
        for (key, model) in models where model.isShown {
            let owner = Self.parts(key).macID
            if macID == nil || owner == nil || owner == macID { model.reconnect() }
        }
        lastWarm = nil
        if !models.isEmpty { warmMedia() }
        if appActive { localhost.resume() }
    }

    /// The app went to the background (or came back): hidden pages let the
    /// WebRTC media session go.
    public func setAppActive(_ active: Bool) {
        appActive = active
        // iOS stops a background app's listeners; they come back with the app.
        if active, isLive { localhost.resume() } else if !active { localhost.suspend() }
        for model in models.values { model.setAppActive(active) }
    }

    public func reset() {
        for model in models.values { model.close() }
        models = [:]
        // No link: nothing to forward `localhost` pages to until it comes back.
        localhost.suspend()
    }
}
