/// Source-independent mirroring for an injected Simulator camera feed.
public enum SimulatorCameraMirrorMode: String, Codable, CaseIterable, Hashable, Sendable {
    /// Let the worker choose based on source and camera position.
    case auto
    /// Always mirror frames horizontally.
    case on
    /// Never mirror frames.
    case off
}
