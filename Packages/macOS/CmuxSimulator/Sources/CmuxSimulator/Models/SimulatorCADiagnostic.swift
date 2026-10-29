/// A Core Animation diagnostic exposed by SimulatorKit.
public enum SimulatorCADiagnostic: String, Codable, CaseIterable, Sendable {
    /// Highlights blended layers.
    case blended
    /// Highlights copied images.
    case copies
    /// Highlights misaligned images.
    case misaligned
    /// Highlights offscreen-rendered content.
    case offscreen
    /// Slows animations for inspection.
    case slowAnimations
}
