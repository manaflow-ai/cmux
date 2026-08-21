import Foundation
import OSLog

private let phoneReplySweepLog = Logger(subsystem: "dev.cmux", category: "phone-reply-inbox")

/// Delivers relayed phone inline-notification replies into the terminal.
///
/// The phone parks a reply in the presence worker with one HTTPS POST (a
/// locked iPhone cannot be trusted to hold a live transport session); this
/// coordinator sweeps the inbox and types each reply through the SAME
/// resolution and injection path the phone's direct RPC send uses
/// (`terminal.input`), so claims, moved surfaces, and dead processes are
/// handled identically on both lanes.
///
/// Sweeps are triggered by the account connectivity WebSocket (the worker
/// re-broadcasts a `connectivity.invalidate` nudge on enqueue), by subscriber
/// (re)starts (a reply parked while this Mac was offline), and by app
/// activation. All triggers coalesce into one debounced pass.
@MainActor
final class PhoneReplyInboxCoordinator {
    static let shared = PhoneReplyInboxCoordinator()

    /// Injection outcome, mapped from the shared terminal.input result codes.
    enum InjectionOutcome {
        /// Typed into the terminal (or queued on its input queue).
        case delivered
        /// The target can never accept it (surface gone, process exited);
        /// acknowledge and drop.
        case permanentlyUndeliverable
        /// Worth retrying on a later sweep (input queue full, surface
        /// temporarily unavailable); leave parked server-side.
        case retryable
    }

    /// Seam to the shared terminal.input entrypoint; wired to
    /// ``TerminalController/v2MobileTerminalInput(params:)`` at composition.
    var injectTerminalInput: (@MainActor ([String: Any]) -> InjectionOutcome)?

    private var client: PhoneReplyInboxClient?
    private var sweepTask: Task<Void, Never>?
    private var sweepQueuedWhileRunning = false
    private var seenReplyIds: PhoneReplySeenSet
    /// Coalesce bursts (nudge frame + reconcile + activation) into one fetch.
    private let debounce: Duration = .milliseconds(500)

    init(defaults: UserDefaults = .standard) {
        seenReplyIds = PhoneReplySeenSet(defaults: defaults)
    }

    func configure(client: PhoneReplyInboxClient) {
        self.client = client
    }

    /// Schedule one debounced sweep. Safe to call from any trigger at any rate.
    func sweepSoon(reason: String) {
        guard client != nil else { return }
        if sweepTask != nil {
            sweepQueuedWhileRunning = true
            return
        }
        phoneReplySweepLog.debug("reply sweep scheduled: \(reason, privacy: .public)")
        sweepTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.sweepTask = nil
                if self.sweepQueuedWhileRunning {
                    self.sweepQueuedWhileRunning = false
                    self.sweepSoon(reason: "queued-during-sweep")
                }
            }
            guard (try? await Task.sleep(for: self.debounce)) != nil else { return }
            await self.sweepOnce()
        }
    }

    private func sweepOnce() async {
        guard let client, let inject = injectTerminalInput else { return }
        guard let pending = await client.fetchPending(), !pending.isEmpty else { return }
        var ackIds: [String] = []
        for reply in pending {
            if seenReplyIds.contains(reply.replyId) {
                // Already injected by a sweep whose ack was lost; never type twice.
                ackIds.append(reply.replyId)
                continue
            }
            var params: [String: Any] = [
                "surface_id": reply.surfaceId,
                // The phone's direct lane submits with a trailing return; the
                // relay lane stores the user's raw text and parity happens here.
                "text": reply.text + "\r",
            ]
            if !reply.workspaceId.isEmpty {
                params["workspace_id"] = reply.workspaceId
            }
            switch inject(params) {
            case .delivered:
                seenReplyIds.insert(reply.replyId)
                ackIds.append(reply.replyId)
                phoneReplySweepLog.info(
                    "relayed phone reply delivered surface=\(reply.surfaceId.prefix(8), privacy: .public)"
                )
            case .permanentlyUndeliverable:
                seenReplyIds.insert(reply.replyId)
                ackIds.append(reply.replyId)
                phoneReplySweepLog.error(
                    "relayed phone reply dropped: target gone surface=\(reply.surfaceId.prefix(8), privacy: .public)"
                )
            case .retryable:
                phoneReplySweepLog.info(
                    "relayed phone reply deferred surface=\(reply.surfaceId.prefix(8), privacy: .public)"
                )
            }
        }
        await client.acknowledge(replyIds: ackIds)
    }
}

/// Small persisted ring of recently injected reply ids. Injection is
/// at-least-once from the server's perspective (a crash between inject and
/// ack re-fetches the reply); typing the same line twice into an agent is
/// worse than the bookkeeping, so recent ids persist across relaunches.
struct PhoneReplySeenSet {
    private static let key = "cmux.phoneReplyInbox.seenReplyIds"
    private static let capacity = 64
    private let defaults: UserDefaults
    private var ordered: [String]

    init(defaults: UserDefaults) {
        self.defaults = defaults
        ordered = defaults.stringArray(forKey: Self.key) ?? []
    }

    func contains(_ replyId: String) -> Bool {
        ordered.contains(replyId)
    }

    mutating func insert(_ replyId: String) {
        guard !ordered.contains(replyId) else { return }
        ordered.append(replyId)
        if ordered.count > Self.capacity {
            ordered.removeFirst(ordered.count - Self.capacity)
        }
        defaults.set(ordered, forKey: Self.key)
    }
}
