import CmuxCloud
import Foundation
import CmuxPhonePush
import OSLog

private let phoneReplySweepLog = Logger(subsystem: "dev.cmux", category: "phone-reply-inbox")

/// Delivers relayed phone inline-notification replies into the terminal.
///
/// The phone parks a reply in the presence worker with one HTTPS POST (a
/// locked iPhone cannot be trusted to hold a live transport session); this
/// coordinator sweeps the inbox and types each reply through the SAME
/// resolution and injection path the phone's direct RPC send uses
/// (`terminal.paste`), so claims, moved surfaces, and dead processes are
/// handled identically on both lanes.
///
/// Sweeps are triggered by the account connectivity WebSocket (the worker
/// re-broadcasts a `connectivity.invalidate` nudge on enqueue), by subscriber
/// (re)starts (a reply parked while this Mac was offline), and by app
/// activation. All triggers coalesce into one debounced pass.
@MainActor
final class PhoneReplyInboxCoordinator {
    static let shared = PhoneReplyInboxCoordinator()

    /// Injection outcome, mapped from the shared terminal.paste result codes.
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

    /// Seam to the shared terminal.paste entrypoint; wired to
    /// ``TerminalController/v2MobileTerminalPaste(params:)`` at composition.
    /// The retarget policy is carried separately so a confined notification
    /// can never be mistaken for a retargetable one after it is parked.
    var injectTerminalInput: (@MainActor ([String: Any], Bool) async -> InjectionOutcome)?

    private var client: PhoneReplyInboxClient?
    private var sweepTask: Task<Void, Never>?
    private var sweepQueuedWhileRunning = false
    private var seenReplyIds: PhoneReplySeenSet
    private var decryptFailureCounts: [String: Int] = [:]
    private static let maxDecryptFailures = 3
    /// Injected so tests drive the debounce and retry delays deterministically
    /// (house rule: no bare Task.sleep in runtime code). Cancellation of the
    /// owning task propagates through the injected sleeper's own throw.
    private let sleep: @Sendable (Duration) async throws -> Void
    private let now: () -> Date
    /// Coalesce bursts (nudge frame + reconcile + activation) into one fetch.
    private let debounce: Duration = .milliseconds(500)
    /// Poll cadence while a fetched reply is transiently undeliverable
    /// (session restore in flight, input queue full); bounded by the reply's
    /// server-side TTL.
    private let retryDelay: Duration = .seconds(3)

    init(
        defaults: UserDefaults = .standard,
        sleep: @escaping @Sendable (Duration) async throws -> Void = {
            try await ContinuousClock().sleep(for: $0)
        },
        now: @escaping () -> Date = Date.init
    ) {
        seenReplyIds = PhoneReplySeenSet(defaults: defaults)
        self.sleep = sleep
        self.now = now
    }

    func configure(client: PhoneReplyInboxClient) {
        self.client = client
    }

    /// Schedule one debounced sweep. Safe to call from any trigger at any rate.
    func sweepSoon(reason: String) {
        guard client != nil else {
            #if DEBUG
            cmuxDebugLog("phoneReply.sweepSkipped reason=\(reason) cause=no_client")
            #endif
            return
        }
        if sweepTask != nil {
            sweepQueuedWhileRunning = true
            return
        }
        #if DEBUG
        cmuxDebugLog("phoneReply.sweepScheduled reason=\(reason)")
        #endif
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
            guard (try? await self.sleep(self.debounce)) != nil else { return }
            await self.sweepOnce()
        }
    }

    private func sweepOnce() async {
        // `DisableRemoteControl` (MDM): a relayed reply is phone input into a
        // terminal, the same as a direct RPC send, so the sweep stays idle
        // under the policy. Parked replies age out server-side.
        guard MobileRemoteControlPolicy.isEnabled,
              MobileHostService.isListeningEnabled else { return }
        guard let client, let inject = injectTerminalInput else {
            #if DEBUG
            cmuxDebugLog("phoneReply.sweepAborted cause=\(client == nil ? "no_client" : "no_injector")")
            #endif
            return
        }
        guard let pending = await client.fetchPending() else {
            #if DEBUG
            cmuxDebugLog("phoneReply.sweepFetchFailed")
            #endif
            return
        }
        let pendingReplyIDs = Set(pending.map(\.replyId))
        decryptFailureCounts = decryptFailureCounts.filter {
            pendingReplyIDs.contains($0.key)
        }
        #if DEBUG
        cmuxDebugLog("phoneReply.sweepFetched count=\(pending.count)")
        #endif
        guard !pending.isEmpty else { return }
        var retryableCount = 0
        var ackIds: [String] = []
        for reply in pending {
            if seenReplyIds.contains(reply.replyId) {
                // Already injected by a sweep whose ack was lost; never type twice.
                ackIds.append(reply.replyId)
                continue
            }
            let decryptOutcome = decrypt(
                reply,
                accountID: await MainActor.run { client.authenticatedAccountID() }
            )
            guard case let .success(decrypted) = decryptOutcome else {
                switch decryptOutcome {
                case .success:
                    break
                case .permanentFailure:
                    decryptFailureCounts.removeValue(forKey: reply.replyId)
                    ackIds.append(reply.replyId)
                    phoneReplySweepLog.error(
                        "relayed phone reply dropped after permanent decrypt failure reply=\(reply.replyId.prefix(8), privacy: .public)"
                    )
                case .retryable:
                    let failures = min(
                        (decryptFailureCounts[reply.replyId] ?? 0) + 1,
                        Self.maxDecryptFailures
                    )
                    decryptFailureCounts[reply.replyId] = failures
                    if failures == Self.maxDecryptFailures {
                        phoneReplySweepLog.error(
                            "relayed phone reply still unavailable after bounded decrypt retries; retaining until expiry reply=\(reply.replyId.prefix(8), privacy: .public)"
                        )
                    }
                    // A retryable decrypt failure can be caused by a temporary
                    // key publication or session race. Keep the record pending
                    // so a later sweep can deliver it before server expiry.
                    retryableCount += 1
                }
                continue
            }
            decryptFailureCounts.removeValue(forKey: reply.replyId)
            var params: [String: Any] = [
                "surface_id": decrypted.surfaceId,
                // Keep the reply text separate from its submit key. Appending a
                // carriage return to terminal.input is a raw byte write and
                // inserts a newline in full-screen agent editors instead of
                // submitting the prompt. The Mac applies the retarget policy
                // from the parked record before invoking terminal.paste.
                "text": decrypted.text,
                "submit_key": "return",
            ]
            if let workspaceId = decrypted.workspaceId, !workspaceId.isEmpty {
                params["workspace_id"] = workspaceId
            }
            let outcome = await inject(params, decrypted.retargetsToLiveSurfaceOwner)
            #if DEBUG
            cmuxDebugLog("phoneReply.inject outcome=\(outcome) surface=\(decrypted.surfaceId.prefix(8))")
            #endif
            switch outcome {
            case .delivered:
                seenReplyIds.insert(reply.replyId)
                ackIds.append(reply.replyId)
                phoneReplySweepLog.info(
                    "relayed phone reply delivered surface=\(decrypted.surfaceId.prefix(8), privacy: .public)"
                )
            case .permanentlyUndeliverable:
                seenReplyIds.insert(reply.replyId)
                ackIds.append(reply.replyId)
                phoneReplySweepLog.error(
                    "relayed phone reply dropped: target gone surface=\(decrypted.surfaceId.prefix(8), privacy: .public)"
                )
            case .retryable:
                retryableCount += 1
                phoneReplySweepLog.info(
                    "relayed phone reply deferred surface=\(decrypted.surfaceId.prefix(8), privacy: .public)"
                )
            }
        }
        await client.acknowledge(replyIds: ackIds)
        if retryableCount > 0 {
            // A transiently unavailable surface (session restore still loading,
            // input queue full) produces no further nudge; poll until the
            // target recovers or the entries age out server-side (15 min TTL
            // bounds this loop).
            guard (try? await sleep(retryDelay)) != nil else { return }
            sweepSoon(reason: "retryable-replies")
        }
    }

    private struct DecryptedReply: Decodable {
        let replyId: String
        let accountID: String
        let issuedAtEpochSeconds: TimeInterval
        let expiresAtEpochSeconds: TimeInterval
        let workspaceId: String?
        let surfaceId: String
        let retargetsToLiveSurfaceOwner: Bool
        let text: String
    }

    private enum DecryptOutcome {
        case success(DecryptedReply)
        case permanentFailure
        case retryable
    }

    private func decrypt(_ reply: PhoneReplyRecord, accountID: String?) -> DecryptOutcome {
        guard let encryptedPayload = reply.encryptedPayload else { return .permanentFailure }
        return decrypt(
            reply,
            encryptedPayload: encryptedPayload,
            accountID: accountID
        )
    }

    private func decrypt(
        _ reply: PhoneReplyRecord,
        encryptedPayload: PhonePushEncryptedPayload,
        accountID: String?
    ) -> DecryptOutcome {
        guard let accountID,
              encryptedPayload.tuple.accountID == accountID,
              encryptedPayload.tuple.macDeviceID == MobileHostIdentity.deviceID(),
              encryptedPayload.tuple.macInstanceTag == MobileHostIdentity.instanceTag() else {
            return .permanentFailure
        }
        let identity: PhonePushKeyMaterial
        do {
            identity = try PhonePushKeyMaterial.current(
                bundleID: Bundle.main.bundleIdentifier ?? "cmux"
            )
        } catch {
            return .retryable
        }
        guard let sender = PhonePushPeerKeyStore().pinnedDescriptor(for: encryptedPayload.tuple) else {
            return .retryable
        }
        let data: Data
        do {
            data = try PhonePushCrypto().decrypt(
                envelope: encryptedPayload,
                tuple: encryptedPayload.tuple,
                recipientInstallationID: identity.installationID,
                recipientKeyID: identity.keyID,
                trustedSenderKeyID: sender.keyID,
                senderPublicKey: sender.publicKey,
                privateKey: identity.privateKey
            )
        } catch {
            return .permanentFailure
        }
        guard let result = try? JSONDecoder().decode(DecryptedReply.self, from: data),
              result.replyId == reply.replyId,
              result.accountID == accountID else { return .permanentFailure }
        guard PhonePushReplyFreshness().accepts(
            issuedAt: result.issuedAtEpochSeconds,
            expiresAt: result.expiresAtEpochSeconds,
            now: now().timeIntervalSince1970
        ) else { return .permanentFailure }
        return .success(result)
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
