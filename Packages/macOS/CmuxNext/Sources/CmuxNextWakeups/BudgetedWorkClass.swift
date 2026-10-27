/// The budgeted subset of ``MainWorkClass`` (userBlocking, visible, automation, background): what a
/// batch (`FrameClient(owner:budgeted:on:onFrame:)`, `FrameBatcher`) runs as, so a batch cannot be
/// made unbudgeted by mistake.
public enum BudgetedWorkClass: Sendable, CaseIterable {
    /// The rest of a person's action (``MainWorkClass/userBlocking``).
    case userBlocking
    case visible
    case automation
    case background

    /// The class in the scheduler's order.
    public var workClass: MainWorkClass {
        switch self {
        case .userBlocking: .userBlocking
        case .visible: .visible
        case .automation: .automation
        case .background: .background
        }
    }
}
