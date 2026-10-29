/// A host capture device offered as a synthetic Simulator camera source.
public struct SimulatorHostCameraDevice: Codable, Equatable, Identifiable, Sendable {
    /// The AVFoundation unique device identifier.
    public let id: String
    /// The localized host camera name.
    public let name: String

    /// Creates host camera metadata.
    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}
