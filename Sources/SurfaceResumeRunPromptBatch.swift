import Foundation

@MainActor
final class SurfaceResumeRunPromptBatch {
    static let shared = SurfaceResumeRunPromptBatch()

    /// Keep a restore pass from admitting an unbounded number of agent
    /// processes at once.  Sessions over this limit remain staged through the
    /// normal deferred-admission path and can be woken when their surface is
    /// shown.  This is deliberately aligned with the routine hibernation
    /// default so a restore cannot defeat the resident-process governor.
    static let maximumAutomaticAgentRestores = 12

    enum StickyDecision {
        case runAll
        case skipAll
    }

    private(set) var stickyDecision: StickyDecision?
    private var activePassDepth = 0
    private var claimedAgentRestoreKeys: Set<String> = []
    private var capacityDeferredAgentRestoreKeys: Set<String> = []

    private init() {}

    var effectiveDecision: StickyDecision? {
        activePassDepth > 0 ? stickyDecision : nil
    }

    var hasActiveRestorePass: Bool { activePassDepth > 0 }

    /// Claims one structured agent checkpoint for the current restore pass.
    /// The first panel carrying an identity owns automatic startup; duplicate
    /// panels remain recoverable without launching a second writer.
    func claimAgentRestore(kind: String, sessionID: String) -> Bool {
        guard activePassDepth > 0 else { return true }
        let key = agentRestoreKey(kind: kind, sessionID: sessionID)
        if claimedAgentRestoreKeys.contains(key) {
            return false
        }
        guard claimedAgentRestoreKeys.count < Self.maximumAutomaticAgentRestores else {
            capacityDeferredAgentRestoreKeys.insert(key)
            return false
        }
        return claimedAgentRestoreKeys.insert(key).inserted
    }

    /// Whether a failed claim was deferred because this restore pass reached
    /// its resident-agent budget. Duplicate records are intentionally not
    /// reported here: those remain duplicate-owner recovery cases.
    func wasDeferredForCapacity(kind: String, sessionID: String) -> Bool {
        guard activePassDepth > 0 else { return false }
        return capacityDeferredAgentRestoreKeys.contains(
            agentRestoreKey(kind: kind, sessionID: sessionID)
        )
    }

    /// Releases a claim when the owning panel could not be attached. This is
    /// intentionally a no-op outside a restore pass so ordinary panel opens
    /// retain their existing admission behavior.
    func releaseAgentRestore(kind: String, sessionID: String) {
        guard activePassDepth > 0 else { return }
        let key = agentRestoreKey(kind: kind, sessionID: sessionID)
        claimedAgentRestoreKeys.remove(key)
        capacityDeferredAgentRestoreKeys.remove(key)
    }

    private func agentRestoreKey(kind: String, sessionID: String) -> String {
        let normalizedKind = kind.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalizedKind + "\u{1f}" + ManagedAgentSessionIdentity.canonicalSessionID(
            kind: normalizedKind,
            sessionID: sessionID
        )
    }

    func beginRestorePass() {
        activePassDepth += 1
    }

    func endRestorePass() {
        activePassDepth -= 1
        if activePassDepth <= 0 {
            activePassDepth = 0
            stickyDecision = nil
            claimedAgentRestoreKeys.removeAll(keepingCapacity: false)
            capacityDeferredAgentRestoreKeys.removeAll(keepingCapacity: false)
        }
    }

    func recordDecision(_ decision: StickyDecision) {
        guard activePassDepth > 0 else { return }
        stickyDecision = decision
    }

    func reset() {
        activePassDepth = 0
        stickyDecision = nil
        claimedAgentRestoreKeys.removeAll(keepingCapacity: false)
        capacityDeferredAgentRestoreKeys.removeAll(keepingCapacity: false)
    }
}
