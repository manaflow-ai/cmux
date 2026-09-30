/// The caller path requesting native runtime surface creation.
enum RuntimeSurfaceCreationSource: Equatable, Sendable {
    /// Normal creation from a ready terminal view.
    case normal

    /// Creation demanded by immediate user input on a visible terminal.
    case inputDemand

    /// Creation from the paced session-restore queue.
    case scheduledRestore

    func promoted(with other: RuntimeSurfaceCreationSource) -> RuntimeSurfaceCreationSource {
        other.priority > priority ? other : self
    }

    private var priority: Int {
        switch self {
        case .normal:
            return 0
        case .scheduledRestore:
            return 1
        case .inputDemand:
            return 2
        }
    }
}
