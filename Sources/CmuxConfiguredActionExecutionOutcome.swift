/// Observable lifecycle state for a configured cmux action.
///
/// Boolean execution APIs remain available for shortcut and menu call sites,
/// while command-palette automation uses this value to distinguish completed
/// work from queued work and UI that owns the remaining interaction.
enum CmuxConfiguredActionExecutionOutcome: Sendable, Equatable {
    case completed
    case queued
    case presented
    case failed

    var isAccepted: Bool {
        switch self {
        case .completed, .queued, .presented:
            true
        case .failed:
            false
        }
    }
}
