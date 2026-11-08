/// Platform role bound into Iroh registration and pairing credentials.
public enum CmxIrohPlatform: String, Codable, Equatable, Sendable {
    /// A cmux host running on macOS.
    case mac

    /// A cmux mobile client running on iOS.
    case ios
}
