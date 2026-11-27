import CmuxNextBrowser
public import CmuxNextWakeups
import Foundation

/// Load states in order; a wait for one is met by it or any later one.
public nonisolated enum LoadState: Int, Comparable, Sendable {
    case commit, domcontentloaded, load

    public init?(name: String) {
        switch name {
        case "commit": self = .commit
        case "domcontentloaded": self = .domcontentloaded
        // No resource-load events yet: networkidle resolves at load (UNVERIFIED
        // against pages that keep fetching after load).
        case "load", "networkidle": self = .load
        default: return nil
        }
    }

    public var name: String {
        switch self {
        case .commit: "commit"
        case .domcontentloaded: "domcontentloaded"
        case .load: "load"
        }
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Pending waits for a tab's main-frame load states, each with a one-shot
/// deadline (`DemandTimer`). Nothing polls: an event resolves the waits it
/// meets; the deadline resolves the rest with `timeout`.
///
/// A wait belongs to the navigation its call started (`WebKitTab.startLoad`
/// and friends return its id). Its commit and load are that navigation's
/// `didCommit` and `didFinish`; its domcontentloaded is the load-state message
/// of the document that commit made; its failure is that navigation's. A
/// commit of any other document (a superseded load, a page's own
/// navigation) never meets it.
///
/// Two engine behaviors differ by macOS version (probed with WKWebView on
/// macOS 26.5 and 27.0):
/// - A load that cannot connect fails provisionally on 27; on 26 the same
///   navigation commits and finishes a blank document (about:blank). A
///   navigation that asked for another URL and commits about:blank failed.
/// - A same-document load (a fragment) gets no delegate callbacks; on 26 the
///   web view's URL shows the `#` as `%23`, so the URL change does not look
///   like a fragment change. Such a navigation never starts; when loading
///   ends and it has not started, it was same-document and its wait is met.
@MainActor
final class LoadWaits {
    /// What a wait is for: `navigation`, or, when the engine started none,
    /// the next document committed after `generation`. A same-document
    /// navigation since the call started (`sameDocuments`) meets it.
    struct Ticket {
        let navigation: BrowserNavigationID?
        /// The URL a load asked for (nil for history and reload).
        let requestedURL: URL?
        let generation: UInt64
        let sameDocuments: UInt64
        let loadingEnds: UInt64
    }

    private struct Wait {
        let target: LoadState
        var navigation: BrowserNavigationID?
        /// Its navigation was replaced (a benign interruption): the next
        /// navigation that starts carries the wait.
        var followsNextNavigation: Bool
        /// Its navigation reported `started` (a cross-document load).
        var started: Bool
        let requestedURL: URL?
        let generation: UInt64
        let timer: DemandTimer?
        let resume: (Result<Void, DriverError>) -> Void
    }

    private var waits: [UUID: Wait] = [:]
    /// Increments at each main-frame document start (load-state message),
    /// for `tab.info` and for tickets without a navigation.
    private(set) var generation: UInt64 = 0
    private(set) var state: LoadState?
    /// The document token of the latest commit: states posted by an older
    /// document (a process swap can deliver them late) are ignored.
    private var document: String?
    /// The navigation that committed last and has no document token yet:
    /// the next document-start message is its document (WebKit sends the
    /// commit before the document's scripts run).
    private var committedNavigation: BrowserNavigationID?
    /// The document `document` belongs to, when a navigation committed it.
    private var documentNavigation: BrowserNavigationID?
    /// Same-document navigations so far. WebKit reports one (the URL KVO)
    /// inside the `load` call that makes it, before the call's wait exists.
    private var sameDocuments: UInt64 = 0
    /// The newest navigation that started (ids grow per tab).
    private var latestStarted: BrowserNavigationID?
    /// Recent navigations that started, for tickets whose wait does not
    /// exist yet (bounded: navigations ids only grow).
    private var startedNavigations: [BrowserNavigationID] = []
    /// Times the web view stopped loading.
    private var loadingEnds: UInt64 = 0

    /// Waits not yet met (tests, diagnostics).
    var pendingCount: Int { waits.count }

    /// Runs `start`, which starts a navigation and returns its id (nil: the
    /// engine started none), and returns the ticket to wait on it with.
    func beginNavigation(requestedURL: URL? = nil, _ start: () -> BrowserNavigationID?) -> Ticket {
        let generation = generation, sameDocuments = sameDocuments, loadingEnds = loadingEnds
        return Ticket(navigation: start(), requestedURL: requestedURL, generation: generation,
                      sameDocuments: sameDocuments, loadingEnds: loadingEnds)
    }

    /// The tab's navigation events (`WebKitTab.observeNavigationEvents`).
    func navigationEvent(_ event: BrowserNavigationEvent) {
        switch event {
        case .started(let id, _):
            if latestStarted.map({ id.rawValue > $0.rawValue }) ?? true { latestStarted = id }
            startedNavigations.append(id)
            if startedNavigations.count > 32 { startedNavigations.removeFirst() }
            for (key, wait) in waits where wait.followsNextNavigation || wait.navigation == id {
                waits[key]?.navigation = id
                waits[key]?.followsNextNavigation = false
                waits[key]?.started = true
            }
        case .committed(let id, let url):
            committedNavigation = id
            for (key, wait) in waits where wait.navigation == id && Self.isBlankErrorDocument(url, requested: wait.requestedURL) {
                finish(key, .failure(DriverError(.invalid, "navigation failed: \(wait.requestedURL?.absoluteString ?? "") did not load")))
            }
            reached(.commit, by: id)
        case .finished(let id):
            reached(.load, by: id)
        case .failed(let id, let error):
            if error.isBenignInterruption {
                // Stopped or replaced: the replacing navigation carries the
                // wait, whether it started before this report or starts later.
                let replacement = latestStarted.flatMap { $0.rawValue > id.rawValue ? $0 : nil }
                for (key, wait) in waits where wait.navigation == id {
                    waits[key]?.navigation = replacement
                    waits[key]?.followsNextNavigation = replacement == nil
                    waits[key]?.started = replacement != nil
                }
            } else {
                for (key, wait) in waits where wait.navigation == id {
                    finish(key, .failure(DriverError(.invalid, "navigation failed: \(error.message)")))
                }
            }
        default:
            break
        }
    }

    /// A main-frame load-state message from the document `token`.
    func signal(_ next: LoadState, document token: String) {
        if next == .commit {
            generation &+= 1
            document = token
            documentNavigation = committedNavigation
            committedNavigation = nil
        } else if token != document {
            return
        }
        state = next
        if let documentNavigation { reached(next, by: documentNavigation) }
        for (key, wait) in waits where wait.navigation == nil && !wait.followsNextNavigation
            && generation > wait.generation && next >= wait.target {
            finish(key, .success(()))
        }
    }

    /// The web view stopped loading. A wait whose navigation never started
    /// was a same-document load: it is met.
    func loadingEnded() {
        loadingEnds &+= 1
        for (key, wait) in waits where wait.navigation != nil && !wait.started && !wait.followsNextNavigation {
            finish(key, .success(()))
        }
    }

    /// A same-document navigation (fragment, pushState): no new document,
    /// every pending wait is met.
    func sameDocument() {
        generation &+= 1
        sameDocuments &+= 1
        state = .load
        for id in Array(waits.keys) { finish(id, .success(())) }
    }

    /// Waits until `ticket`'s navigation reaches `target`; `timeout` nil
    /// waits without a deadline.
    func reach(_ target: LoadState, for ticket: Ticket, timeout: Duration?, what: String) async throws(DriverError) {
        if sameDocuments > ticket.sameDocuments { return }
        let started = ticket.navigation.map(startedNavigations.contains) ?? false
        if ticket.navigation != nil, !started, loadingEnds > ticket.loadingEnds { return }
        if ticket.navigation == nil, generation > ticket.generation, let state, state >= target { return }
        let id = UUID()
        let result: Result<Void, DriverError> = await withCheckedContinuation { continuation in
            let timer = timeout.map { _ in DemandTimer(owner: "BrowserAutomation.loadWait") }
            waits[id] = Wait(target: target, navigation: ticket.navigation, followsNextNavigation: false, started: started,
                             requestedURL: ticket.requestedURL, generation: ticket.generation, timer: timer) {
                continuation.resume(returning: $0)
            }
            if let timer, let timeout {
                timer.schedule(after: timeout) { [weak self] in
                    await self?.finish(id, .failure(DriverError(.timeout, "\(what): Timeout \(timeout) exceeded waiting for \(target.name)")))
                }
            }
        }
        try result.get()
    }

    /// Fails every pending wait (the tab closed or crashed).
    func failAll(_ error: DriverError) {
        for id in Array(waits.keys) { finish(id, .failure(error)) }
    }

    /// macOS 26 commits a blank document for a load that cannot connect.
    static func isBlankErrorDocument(_ committed: URL?, requested: URL?) -> Bool {
        guard let requested, requested.scheme?.lowercased() != "about" else { return false }
        return committed?.absoluteString == "about:blank"
    }

    private func reached(_ state: LoadState, by navigation: BrowserNavigationID) {
        for (key, wait) in waits where wait.navigation == navigation && state >= wait.target {
            finish(key, .success(()))
        }
    }

    private func finish(_ id: UUID, _ result: Result<Void, DriverError>) {
        guard let wait = waits.removeValue(forKey: id) else { return }
        wait.timer?.cancel()
        wait.resume(result)
    }
}
