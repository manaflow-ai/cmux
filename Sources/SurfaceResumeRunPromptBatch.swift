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
        let normalizedKind = kind.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = normalizedKind + "\u{1f}" + ManagedAgentSessionIdentity.canonicalSessionID(
            kind: normalizedKind,
            sessionID: sessionID
        )
        return claimedAgentRestoreKeys.insert(key).inserted
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
