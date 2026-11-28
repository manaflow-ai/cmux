import Observation

/// Changes whenever a window mounts or releases a pane controller. Pane
/// controllers live in non-observable window content, so code that waits
/// for a pane to mount (Cmd-I on a workspace that is still empty) observes
/// this generation and then looks the controller up.
@Observable @MainActor
final class PaneMounts {
    private(set) var generation: UInt64 = 0

    func changed() { generation &+= 1 }
}
