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
/// commit of any other document (a fresh web view's initial about:blank on
/// macOS 26, a superseded load) never meets it. Counting commits, as this
/// type once did, let that about:blank answer a navigation that then failed.
@MainActor
final class LoadWaits {
    /// What a wait is for: `navigation`, or, when the engine started none,
    /// the next document committed after `generation`. A same-document
    /// navigation since the call started (`sameDocuments`) meets it.
    struct Ticket {
        let navigation: BrowserNavigationID?
        let generation: UInt64
        let sameDocuments: UInt64
    }

    private struct Wait {
        let target: LoadState
        var navigation: BrowserNavigationID?
        /// Its navigation was replaced (a benign interruption): the next
        /// navigation that starts carries the wait.
        var followsNextNavigation: Bool
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

    /// Waits not yet met (tests, diagnostics).
    var pendingCount: Int { waits.count }

    /// Runs `start`, which starts a navigation and returns its id (nil: the
    /// engine started none), and returns the ticket to wait on it with.
    func beginNavigation(_ start: () -> BrowserNavigationID?) -> Ticket {
        let generation = generation, sameDocuments = sameDocuments
        return Ticket(navigation: start(), generation: generation, sameDocuments: sameDocuments)
    }

    /// The tab's navigation events (`WebKitTab.observeNavigationEvents`).
    func navigationEvent(_ event: BrowserNavigationEvent) {
        switch event {
        case .started(let id, _):
            if latestStarted.map({ id.rawValue > $0.rawValue }) ?? true { latestStarted = id }
            for (key, wait) in waits where wait.followsNextNavigation {
                waits[key]?.navigation = id
                waits[key]?.followsNextNavigation = false
            }
        case .committed(let id, _):
            committedNavigation = id
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
        if ticket.navigation == nil, generation > ticket.generation, let state, state >= target { return }
        let id = UUID()
        let result: Result<Void, DriverError> = await withCheckedContinuation { continuation in
            let timer = timeout.map { _ in DemandTimer(owner: "BrowserAutomation.loadWait") }
            waits[id] = Wait(target: target, navigation: ticket.navigation, followsNextNavigation: false,
                             generation: ticket.generation, timer: timer) { continuation.resume(returning: $0) }
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
