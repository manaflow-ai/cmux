public import Foundation
public import Observation
import CmuxNextWakeups
import class CmuxSafeConcurrency.OnceContinuation
import enum CmuxSafeConcurrency.OnceContinuationError
import func CmuxSafeConcurrency.withOnceContinuation

/// The one path every agent permission request takes (socket
/// `permissions.request`, the CLI verb, the MCP tool):
/// plans/cmux-next/agent-permissions-DESIGN.md section 2.
///
/// A grant that is on answers at once. Otherwise the request waits in
/// arrival order and ``current`` is the one the card shows; the same grant
/// from the same agent joins the request already waiting. Nothing opens
/// System Settings or shows a macOS prompt until ``continueCurrent()`` (the
/// person's Continue). ``denyCurrent()`` ends the request with `denied`.
/// While the card guides, each ``PermissionProbe/changes()`` element re-reads
/// the grant; the request ends `granted` when it lands. A request nobody
/// answers ends `timedOut` after its timeout, on the injected clock.
///
/// ```swift
/// let requests = AgentPermissionRequests(probe: MockPermissionProbe(), opener: opener)
/// let outcome = await requests.request(PermissionRequest(kind: .fullDiskAccess, reason: "Read Mail to find invoices",
///                                                        prompt: "find my invoices", requester: requester),
///                                      timeout: .seconds(300))
/// ```
@MainActor
@Observable
public final class AgentPermissionRequests {
    /// The request the card shows, nil when none waits.
    public private(set) var current: PendingPermissionRequest?
    /// Requests waiting behind ``current``, oldest first.
    public private(set) var queued: [PendingPermissionRequest] = []
    /// The last request that ended `granted` (the card's short confirm), until the next one shows.
    public private(set) var lastGranted: PendingPermissionRequest?

    @ObservationIgnored private let probe: any PermissionProbe
    @ObservationIgnored private let opener: any PermissionSettingsOpening
    @ObservationIgnored private let clock: any Clock<Duration>
    @ObservationIgnored private let makeID: () -> String
    @ObservationIgnored private var waiters: [String: [OnceContinuation<PermissionOutcome, OnceContinuationError>]] = [:]
    @ObservationIgnored private var timeouts: [String: DemandTimer] = [:]
    @ObservationIgnored private var watch: Task<Void, Never>?

    /// - Parameters:
    ///   - probe: reads grants without prompting (``MockPermissionProbe`` in tests).
    ///   - opener: opens System Settings or the macOS prompt after Continue.
    ///   - clock: drives request timeouts; tests pass a manual clock.
    ///   - makeID: mints request ids (`perm_` plus a UUID by default).
    public init(probe: any PermissionProbe, opener: any PermissionSettingsOpening, clock: any Clock<Duration> = ContinuousClock(),
                makeID: @escaping () -> String = { "perm_" + UUID().uuidString.lowercased() }) {
        self.probe = probe
        self.opener = opener
        self.clock = clock
        self.makeID = makeID
    }

    /// Every request that waits, ``current`` first.
    public var pending: [PendingPermissionRequest] { (current.map { [$0] } ?? []) + queued }

    /// Asks for `request.kind` and returns when the request ends.
    ///
    /// - Parameters:
    ///   - request: the grant, the agent's reason, the person's prompt and the requester.
    ///   - timeout: how long the request may wait for the person.
    /// - Returns: the outcome; `alreadyGranted` without a card when the grant is on.
    public func request(_ request: PermissionRequest, timeout: Duration) async -> PermissionOutcome {
        let verdict = request.reasonCheck.verdict
        if await probe.status(request.kind, target: request.target) == .granted {
            return PermissionOutcome(kind: request.kind, result: .alreadyGranted, requestID: nil, reasonCheck: verdict)
        }
        // A waiter dropped without an answer reads as withdrawn (cancelled).
        let abandoned = PermissionOutcome(kind: request.kind, result: .cancelled, requestID: nil, reasonCheck: verdict)
        return (try? await withOnceContinuation { (continuation: OnceContinuation<PermissionOutcome, OnceContinuationError>) in
            if let joined = pending.first(where: { $0.request.joins(request) }) {
                waiters[joined.id, default: []].append(continuation)
                update(joined.id) { $0.callers += 1 }
                return
            }
            let pendingRequest = PendingPermissionRequest(id: makeID(), request: request)
            waiters[pendingRequest.id] = [continuation]
            if current == nil {
                lastGranted = nil
                current = pendingRequest
            } else {
                queued.append(pendingRequest)
            }
            startTimeout(pendingRequest.id, after: timeout)
        }) ?? abandoned
    }

    /// The person pressed Continue: open the list (or the macOS prompt) for
    /// the first grant still off and follow the grant.
    public func continueCurrent() {
        guard var shown = current, shown.phase == .asking else { return }
        shown.phase = .guiding
        current = shown
        followGrants(of: shown.id)
    }

    /// The person pressed Deny.
    public func denyCurrent() {
        guard let shown = current else { return }
        finish(shown.id, .denied)
    }

    /// Withdraws a request (the agent cancelled, or its connection closed).
    public func cancel(_ id: String) {
        finish(id, .cancelled)
    }

    /// Ends a request with `unavailable` (the App found no way to grant it in this build).
    public func markUnavailable(_ id: String) {
        finish(id, .unavailable)
    }

    // MARK: Following the grant

    private func followGrants(of id: String) {
        watch?.cancel()
        let probe = probe
        let changes = probe.changes()
        // task-owner: follows the shown request's grant; finish() and a newer Continue cancel it.
        watch = Task { [weak self] in
            guard let self else { return }
            if await advance(id) { return }
            for await _ in changes {
                guard !Task.isCancelled else { return }
                if await advance(id) { return }
            }
        }
    }

    /// Reads the grants of the guided request; opens the next list when one
    /// is still off, or ends the request when all are on. True when it ended.
    private func advance(_ id: String) async -> Bool {
        guard let shown = current, shown.id == id else { return true }
        for grant in shown.request.kind.grants {
            let status = await probe.status(grant, target: shown.request.target)
            guard current?.id == id else { return true }
            if status == .granted { continue }
            if current?.guidingGrant != grant {
                update(id) { $0.guidingGrant = grant }
                opener.open(grant, target: shown.request.target)
            }
            return false
        }
        finish(id, .granted)
        return true
    }

    // MARK: Ending

    private func startTimeout(_ id: String, after timeout: Duration) {
        // The request's one deadline; finish() cancels it.
        let timer = DemandTimer(owner: "agent-permissions.request-timeout", clock: clock)
        timer.scheduleOnMain(after: timeout) { [weak self] in self?.finish(id, .timedOut) }
        timeouts[id] = timer
    }

    private func finish(_ id: String, _ result: PermissionOutcome.Result) {
        let ended: PendingPermissionRequest
        if let shown = current, shown.id == id {
            ended = shown
            watch?.cancel()
            watch = nil
            current = queued.isEmpty ? nil : queued.removeFirst()
        } else if let index = queued.firstIndex(where: { $0.id == id }) {
            ended = queued.remove(at: index)
        } else {
            return
        }
        lastGranted = result == .granted ? ended : (current == nil ? lastGranted : nil)
        timeouts.removeValue(forKey: id)?.cancel()
        let outcome = PermissionOutcome(kind: ended.request.kind, result: result, requestID: id, reasonCheck: ended.reasonCheck)
        for waiter in waiters.removeValue(forKey: id) ?? [] { waiter.resume(returning: outcome) }
    }

    private func update(_ id: String, _ change: (inout PendingPermissionRequest) -> Void) {
        if var shown = current, shown.id == id {
            change(&shown)
            current = shown
        } else if let index = queued.firstIndex(where: { $0.id == id }) {
            change(&queued[index])
        }
    }
}
