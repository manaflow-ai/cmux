import Foundation

@MainActor
final class SurfaceResumeRunPromptBatch {
    static let shared = SurfaceResumeRunPromptBatch()

    enum StickyDecision {
        case runAll
        case skipAll
    }

    var stickyDecision: StickyDecision?

    private init() {}

    func reset() {
        stickyDecision = nil
    }
}
