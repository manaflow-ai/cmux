import CmuxWorkspaces

/// Process evidence used to decide whether a restorable agent should resume automatically.
enum RestorableAgentProcessLiveness: Equatable, Sendable {
    case running
    case exited
    case unknown

    /// Resolves process evidence first and uses shell activity only when no process conclusion exists.
    func wasRunning(fallingBackTo shellActivityState: PanelShellActivityState?) -> Bool? {
        switch self {
        case .running:
            return true
        case .exited:
            return false
        case .unknown:
            switch shellActivityState {
            case .some(.commandRunning):
                return true
            case .some(.promptIdle):
                return false
            case .some(.unknown), .none:
                return nil
            }
        }
    }
}
