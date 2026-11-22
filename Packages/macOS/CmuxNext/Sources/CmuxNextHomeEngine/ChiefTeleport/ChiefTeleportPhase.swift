/// Where a Chief move or rollback started from the app is (the chip's progress): a dry run, the
/// move, the check on the target, then its result. The associated text is the target's name as the
/// menu shows it ("cmux Cloud", "Mac mini").
public nonisolated enum ChiefTeleportPhase: Equatable, Sendable {
    /// No move runs and none finished since the app started.
    case idle
    /// `cmux chief move --dry-run`: the target is checked, nothing moves yet.
    case checking(String)
    /// The move itself: drain, checkpoint, send, restore, verify.
    case moving(String)
    /// `move reach` on the target after the move.
    case verifying(String)
    /// The Chief runs at the target now.
    case done(String)
    /// The move stopped; `reason` is what the engine said.
    case failed(String, reason: String)
    /// `cmux chief move rollback` runs.
    case rollingBack
    /// The rollback finished: the Chief answers from this Mac again.
    case rolledBack

    /// A move or rollback is running: the menu starts no other one.
    public var isRunning: Bool {
        switch self {
        case .checking, .moving, .verifying, .rollingBack: true
        case .idle, .done, .failed, .rolledBack: false
        }
    }
}
