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

    private init() {}

    var effectiveDecision: StickyDecision? {
        activePassDepth > 0 ? stickyDecision : nil
    }

    func beginRestorePass() {
        activePassDepth += 1
    }

    func endRestorePass() {
        activePassDepth -= 1
        if activePassDepth <= 0 {
            activePassDepth = 0
            stickyDecision = nil
        }
    }

    func recordDecision(_ decision: StickyDecision) {
        guard activePassDepth > 0 else { return }
        stickyDecision = decision
    }

    func reset() {
        activePassDepth = 0
        stickyDecision = nil
    }
}
