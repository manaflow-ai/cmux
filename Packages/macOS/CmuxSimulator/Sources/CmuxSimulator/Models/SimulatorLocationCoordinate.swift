/// A geographic point accepted by `simctl location`.
public struct SimulatorLocationCoordinate: Codable, Equatable, Sendable {
    /// Latitude in degrees, from -90 through 90.
    public let latitude: Double
    /// Longitude in degrees, from -180 through 180.
    public let longitude: Double

    /// Creates a geographic point.
    /// - Parameters:
    ///   - latitude: Latitude in degrees.
    ///   - longitude: Longitude in degrees.
    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }
}
