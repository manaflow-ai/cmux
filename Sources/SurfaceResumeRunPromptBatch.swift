import Foundation

@MainActor
final class SurfaceResumeRunPromptBatch {
    static let shared = SurfaceResumeRunPromptBatch()

    enum StickyDecision {
        case runAll
        case skipAll
    }

    private(set) var stickyDecision: StickyDecision?
    private var activePassDepth = 0
    private var claimedAgentRestoreKeys: Set<String> = []

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
        return claimedAgentRestoreKeys.insert(key).inserted
    }

    /// Releases a claim when the owning panel could not be attached. This is
    /// intentionally a no-op outside a restore pass so ordinary panel opens
    /// retain their existing admission behavior.
    func releaseAgentRestore(kind: String, sessionID: String) {
        guard activePassDepth > 0 else { return }
        claimedAgentRestoreKeys.remove(agentRestoreKey(kind: kind, sessionID: sessionID))
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
    }
}
