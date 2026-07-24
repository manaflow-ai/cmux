/// One typed record on a semantic terminal scene lane.
public enum CmxIrohTerminalSceneEnvelope: Equatable, Sendable {
    /// The first record, used to create the exact Ghostty renderer.
    case configuration(CmxIrohTerminalSceneConfiguration)

    /// A full, delta, or presentation-only Ghostty scene.
    case scene(CmxIrohTerminalSceneFrame)
}
