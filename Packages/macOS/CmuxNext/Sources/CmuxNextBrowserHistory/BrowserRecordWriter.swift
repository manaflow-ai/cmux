public import CmuxNextBrowser
import CmuxNextCompat
public import CmuxNextDaemon
public import Foundation
import Observation

/// The url, title, and favicon the daemon records for a frontend browser
/// tab (`frontend-browser-tabs-v1`), and on daemons with state resources
/// its zoom and back/forward lists (`tab.update`). The engine is the live
/// source; the record is what survives relaunch.
public struct BrowserRecord: Equatable, Sendable {
    public var url: String?
    public var title: String?
    public var faviconURL: String?
    /// Page zoom; nil = 100 %.
    public var zoom: Double?
    public var back: [String] = []
    public var forward: [String] = []

    public init(url: String? = nil, title: String? = nil, faviconURL: String? = nil, zoom: Double? = nil, back: [String] = [],
         forward: [String] = []) {
        self.url = url
        self.title = title
        self.faviconURL = faviconURL
        self.zoom = zoom
        self.back = back
        self.forward = forward
    }

    public init(tab: TabModel) {
        self.init(url: tab.url, title: tab.title.isEmpty ? nil : tab.title, faviconURL: tab.faviconURL, zoom: tab.zoom,
                  back: tab.backURLs, forward: tab.forwardURLs)
    }

    /// The fields to send to move this record to `page`, or nil when nothing
    /// changed. A page without a URL (nothing committed yet) or title keeps
    /// the recorded value; the favicon is cleared only once a load finished
    /// without one. Zoom and history are compared only with `state` (the
    /// daemon keeps them), history only when the engine reports it.
    public func update(toward page: BrowserTabState, state: Bool = false) -> BrowserRecordUpdate? {
        let pageURL = page.url?.absoluteString
        let url = pageURL.flatMap { $0 == self.url ? nil : $0 }
        let title = page.title.flatMap { $0.isEmpty || $0 == self.title ? nil : $0 }
        let favicon: FieldUpdate<String>
        if let icon = page.faviconURL?.absoluteString {
            favicon = icon == faviconURL ? .unchanged : .set(icon)
        } else if faviconURL != nil, case .finished = page.phase {
            favicon = .clear
        } else {
            favicon = .unchanged
        }
        var update = BrowserRecordUpdate(url: url, title: title, favicon: favicon)
        if state {
            let zoom = abs(page.zoom - 1) < 0.001 ? nil : page.zoom
            if zoom != self.zoom { update.zoom = zoom.map(FieldUpdate.set) ?? .clear }
            if let back = page.backURLs, back != self.back { update.back = back }
            if let forward = page.forwardURLs, forward != self.forward { update.forward = forward }
        }
        return update.isEmpty ? nil : update
    }

    public func applying(_ update: BrowserRecordUpdate) -> BrowserRecord {
        var next = self
        if let url = update.url { next.url = url }
        if let title = update.title { next.title = title }
        switch update.favicon {
        case .unchanged: break
        case .clear: next.faviconURL = nil
        case .set(let value): next.faviconURL = value
        }
        switch update.zoom {
        case .unchanged: break
        case .clear: next.zoom = nil
        case .set(let value): next.zoom = value
        }
        if let back = update.back { next.back = back }
        if let forward = update.forward { next.forward = forward }
        return next
    }
}

/// One write-back: `update-frontend-browser-tab` fields (url, title,
/// favicon) and `tab.update` fields (zoom, back, forward).
public struct BrowserRecordUpdate: Equatable, Sendable {
    public var url: String?
    public var title: String?
    public var favicon: FieldUpdate<String>
    public var zoom: FieldUpdate<Double> = .unchanged
    public var back: [String]?
    public var forward: [String]?

    public init(url: String?, title: String?, favicon: FieldUpdate<String>, zoom: FieldUpdate<Double> = .unchanged,
         back: [String]? = nil, forward: [String]? = nil) {
        self.url = url
        self.title = title
        self.favicon = favicon
        self.zoom = zoom
        self.back = back
        self.forward = forward
    }

    /// Fields `update-frontend-browser-tab` carries.
    public var hasRecordFields: Bool { url != nil || title != nil || favicon != .unchanged }
    /// Fields `tab.update` carries.
    public var hasStateFields: Bool { zoom != .unchanged || back != nil || forward != nil }
    public var isEmpty: Bool { !hasRecordFields && !hasStateFields }
}

/// Writes a live page's record back to its daemon tab, throttled: the first
/// page change opens one `delay` window and its end writes the latest state,
/// so a burst of navigation events sends one command, and a page that never
/// settles (a ticking title) still writes once per window. A failed send keeps the old record, so the
/// next change retries the full difference. The copy follows the daemon:
/// each change of the tab's daemon record (`daemonRecord`, another client,
/// a restore, this writer's own echo) re-bases it, so a difference is always
/// computed against what the daemon holds. A web address another client
/// wrote is loaded in the page instead of being written back over
/// (`workspace.open_url` reusing the tab, cx-ebm.59.6).
///
/// Whose write a record change is comes from causal order, not from matching
/// echoes against what was sent: `send` returns only once the store
/// has applied every event up to the write's reply (`BrowserTabService.settled`,
/// OWNERSHIP-PRINCIPLES "an intent leaves the log on its echo"). While a write
/// is unsettled the record may still show older states, this writer's own
/// echoes included, so nothing is followed; once every write settles, the
/// record names this writer's address, the address it held before, or another
/// client's (another client writing exactly one of those addresses meanwhile is
/// not told apart), and from then on every change is another client's. Matching echoes
/// by address dropped an echo the daemon published after its reply, and Google
/// Maps (a new URL on every pan) reloaded at an old viewport every few seconds.
public final class BrowserRecordWriter {
    public typealias Send = @MainActor (BrowserRecordUpdate) async -> Bool
    public typealias Sleep = @Sendable (Duration) async throws -> Void

    public private(set) var recorded: BrowserRecord
    private let delay: Duration
    private let sleep: Sleep
    private let send: Send
    /// Compare zoom and history too (the daemon keeps them).
    private let tracksState: Bool
    private var page: BrowserTabState?
    private var observation: Task<Void, Never>?
    private var rebasing: Task<Void, Never>?
    private var pending: Task<Void, Never>?
    /// The page change the pending write waits to send.
    private var unsent: BrowserTabState?
    /// The page as it is now, its address as the record keeps it. The
    /// observation hears of a change only on a later turn.
    private let current: @MainActor () -> BrowserTabState
    /// Loads a web address another client wrote to the record (nil for a machine's page, whose
    /// record keeps the machine address).
    private let follow: (@MainActor (URL) -> Void)?
    /// The tab's daemon record as the store holds it now.
    private let daemonRecord: (@MainActor () -> BrowserRecord?)?
    /// Writes sent whose events the store has not applied yet. Record changes seen meanwhile
    /// may be older than this writer's writes and are never followed.
    private var unsettledWrites = 0
    /// While writes are unsettled: the record's address when the first of them went out and
    /// every address they sent. Once all settle, a record address outside these is another
    /// client's write.
    private var ownURLs: Set<String> = []
    /// The page's address when it was told to follow the record: until the page leaves it (a
    /// hibernated page loads on wake), its changes are not written back over the new address.
    private var followedFrom: URL?

    /// `recordURL` maps the page's address to the address the record keeps
    /// (a machine's page keeps its machine record, cx-2cob slice 2).
    public init(tab: any BrowserTab, recorded: BrowserRecord, tracksState: Bool = false,
         daemonRecord: (@MainActor () -> BrowserRecord?)? = nil, recordURL: (@MainActor (URL) -> URL)? = nil,
         delay: Duration, sleep: @escaping Sleep, send: @escaping Send) {
        self.recorded = recorded
        self.tracksState = tracksState
        self.delay = delay
        self.sleep = sleep
        self.send = send
        self.daemonRecord = daemonRecord
        let current: @MainActor () -> BrowserTabState = { [tab] in
            var state = tab.state
            if let recordURL { state.url = state.url.map(recordURL) }
            return state
        }
        self.current = current
        let load: @MainActor (URL) -> Void = { [tab] url in tab.load(url) }
        follow = recordURL == nil ? load : nil
        observation = Task { [weak self, tab] in
            for await _ in ObservationStream({ tab.state }) {
                self?.pageDidChange(current())
            }
        }
        if let daemonRecord {
            rebasing = Task { [weak self] in
                for await record in ObservationStream({ daemonRecord() }) {
                    guard let record else { continue }
                    self?.rebase(record)
                }
            }
        }
    }

    /// Sends the page's change now (quit, close: the app or the record may
    /// be gone before the delay ends), including one the observation has
    /// not delivered yet.
    public func flushNow() async {
        pending?.cancel()
        pending = nil
        unsent = nil
        let state = current()
        page = state
        // A page that has not left the address it was told to leave yet writes nothing over the record.
        if let from = followedFrom, state.url == from { return }
        await flush(state)
    }

    public func cancel() {
        observation?.cancel()
        rebasing?.cancel()
        pending?.cancel()
        observation = nil
        rebasing = nil
        pending = nil
    }

    /// The daemon's record changed: compare the page against it from now on.
    private func rebase(_ record: BrowserRecord) {
        let record = comparable(record)
        guard record != recorded else { return }
        let previous = recorded
        recorded = record
        // A change seen while a write is unsettled may be an older state or another client's:
        // the end of the writes decides, so nothing is written over it before then (the page's
        // own navigations still are). One seen with no write unsettled is ordered after every
        // write of this writer: it is another client's.
        guard unsettledWrites == 0 else { return }
        if let text = record.url, text != previous.url, loadIfForeign(text) { return }
        if let page { pageDidChange(page) }
    }

    /// `record` with the fields the daemon does not keep taken from the local copy: zoom and
    /// history are compared only when the daemon keeps them, so they never look changed.
    private func comparable(_ record: BrowserRecord) -> BrowserRecord {
        guard !tracksState else { return record }
        var record = record
        record.zoom = recorded.zoom
        record.back = recorded.back
        record.forward = recorded.forward
        return record
    }

    /// Another client moved the record to the web address `text` (`workspace.open_url` reusing
    /// this tab, cx-ebm.59.6): the page loads it, as `cmux browser navigate` does, instead of
    /// writing its old address back. Other schemes, a machine's page and the address the page
    /// shows are written back over as before. True when the page loads it.
    private func loadIfForeign(_ text: String) -> Bool {
        let shown = current().url
        guard let follow, let url = URL(string: text), url.absoluteString != shown?.absoluteString,
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return false }
        pending?.cancel()
        (pending, unsent, followedFrom) = (nil, nil, shown)
        follow(url)
        return true
    }

    private func pageDidChange(_ state: BrowserTabState) {
        page = state
        if let from = followedFrom {
            guard state.url != from else { return }
            followedFrom = nil
        }
        guard recorded.update(toward: state, state: tracksState) != nil else {
            pending?.cancel()
            pending = nil
            unsent = nil
            return
        }
        unsent = state
        // The first change opens one `delay` window and its end writes the latest state. A change
        // inside the window does not restart it: a page whose title ticks faster than `delay` (a
        // timer, a ticker) never let a restarting debounce write its address or history.
        guard pending == nil else { return }
        let delay = delay, sleep = sleep
        pending = Task { [weak self] in
            do { try await sleep(delay) } catch { return } // wakeup-allow: one `delay` write window per burst of changes; flushNow() and cancel() cancel it
            guard let self, !Task.isCancelled else { return }
            let latest = self.unsent
            self.pending = nil
            self.unsent = nil
            if let latest { await self.flush(latest) }
        }
    }

    private func flush(_ state: BrowserTabState) async {
        guard let update = recorded.update(toward: state, state: tracksState) else { return }
        let base = recorded
        if unsettledWrites == 0, let url = base.url { ownURLs.insert(url) }
        if let url = update.url { ownURLs.insert(url) }
        unsettledWrites += 1
        let sent = await send(update)
        unsettledWrites -= 1
        guard let daemonRecord else {
            if sent, recorded == base { recorded = base.applying(update) }
            return
        }
        guard unsettledWrites == 0 else { return }
        // Every write settled: the store's record holds each of their events and every event
        // before them. A failed send settles too, as the record command may have landed before
        // a later step failed.
        let own = ownURLs
        ownURLs = []
        guard let record = daemonRecord().map(comparable) else { return }
        recorded = record
        if let text = record.url, !own.contains(text), loadIfForeign(text) { return }
        // A page that moved on while the write was out writes again; a failed send waits for
        // the next change, as before.
        if sent, let page { pageDidChange(page) }
    }
}
