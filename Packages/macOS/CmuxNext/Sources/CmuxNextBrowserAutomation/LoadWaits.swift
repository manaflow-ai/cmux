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
/// deadline (`DemandTimer`). Nothing polls: a load-state message resolves
/// the waits it meets; the deadline resolves the rest with `timeout`.
@MainActor
final class LoadWaits {
    private struct Wait {
        let target: LoadState
        let afterGeneration: UInt64
        let timer: DemandTimer?
        let resume: (Result<Void, DriverError>) -> Void
    }

    private var waits: [UUID: Wait] = [:]
    /// Increments at each main-frame commit, so a wait started before a
    /// navigation ignores the previous document's states.
    private(set) var generation: UInt64 = 0
    private(set) var state: LoadState?
    /// The document token of the latest commit: states posted by an older
    /// document (a process swap can deliver them late) are ignored.
    private var document: String?

    /// Marks the start of a navigation the caller will wait for.
    func beginNavigation() -> UInt64 { generation }

    func signal(_ next: LoadState, document token: String) {
        if next == .commit {
            generation &+= 1
            document = token
        } else if token != document {
            return
        }
        state = next
        for (id, wait) in waits where generation > wait.afterGeneration && next >= wait.target {
            finish(id, .success(()))
        }
    }

    /// A same-document navigation (fragment, pushState): no new document,
    /// every pending wait is met.
    func sameDocument() {
        generation &+= 1
        state = .load
        for id in Array(waits.keys) { finish(id, .success(())) }
    }

    /// Fails waits that no commit met since they began (the navigation
    /// failed or was cancelled before a document committed).
    func navigationFailed(_ error: DriverError) {
        for (id, wait) in waits where wait.afterGeneration == generation { finish(id, .failure(error)) }
    }

    /// Waits until the main frame reaches `target` in a document committed
    /// after `generation`; `timeout` nil waits without a deadline.
    func reach(_ target: LoadState, after generation: UInt64, timeout: Duration?, what: String) async throws(DriverError) {
        if self.generation > generation, let state, state >= target { return }
        let id = UUID()
        let result: Result<Void, DriverError> = await withCheckedContinuation { continuation in
            let timer = timeout.map { _ in DemandTimer(owner: "BrowserAutomation.loadWait") }
            waits[id] = Wait(target: target, afterGeneration: generation, timer: timer) { continuation.resume(returning: $0) }
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

    private func finish(_ id: UUID, _ result: Result<Void, DriverError>) {
        guard let wait = waits.removeValue(forKey: id) else { return }
        wait.timer?.cancel()
        wait.resume(result)
    }
}
