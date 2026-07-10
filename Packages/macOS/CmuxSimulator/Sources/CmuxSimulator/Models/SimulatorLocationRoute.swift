import Foundation

/// A route interpolated by `simctl location start`.
public struct SimulatorLocationRoute: Equatable, Sendable {
    /// Ordered waypoints. A valid route contains at least two points.
    public let waypoints: [SimulatorLocationCoordinate]
    /// Travel speed in meters per second.
    public let speed: Double
    /// Optional distance between emitted location updates, in meters.
    public let updateDistance: Double?
    /// Optional interval between emitted location updates, in seconds.
    public let updateInterval: Double?
    /// Whether playback restarts after the final waypoint.
    public let loops: Bool

    /// Creates a simulated route.
    /// - Parameters:
    ///   - waypoints: Ordered route points.
    ///   - speed: Travel speed in meters per second.
    ///   - updateDistance: Optional distance between updates.
    ///   - updateInterval: Optional interval between updates.
    ///   - loops: Whether playback restarts after the final waypoint.
    public init(
        waypoints: [SimulatorLocationCoordinate],
        speed: Double,
        updateDistance: Double? = nil,
        updateInterval: Double? = nil,
        loops: Bool = false
    ) {
        self.waypoints = waypoints
        self.speed = speed
        self.updateDistance = updateDistance
        self.updateInterval = updateInterval
        self.loops = loops
    }

    /// Estimated wall-clock time needed to traverse the route at its configured speed.
    public var estimatedDuration: TimeInterval? {
        guard waypoints.count >= 2, speed.isFinite, speed > 0 else { return nil }
        var points = waypoints
        if loops, let first = points.first, points.last != first {
            points.append(first)
        }
        let totalDistance = zip(points, points.dropFirst()).reduce(0) { total, segment in
            total + distance(from: segment.0, to: segment.1)
        }
        guard totalDistance.isFinite, totalDistance > 0 else { return nil }
        return totalDistance / speed
    }

    private func distance(
        from start: SimulatorLocationCoordinate,
        to end: SimulatorLocationCoordinate
    ) -> Double {
        let earthRadius = 6_371_000.0
        let latitude1 = start.latitude * .pi / 180
        let latitude2 = end.latitude * .pi / 180
        let latitudeDelta = (end.latitude - start.latitude) * .pi / 180
        let longitudeDelta = (end.longitude - start.longitude) * .pi / 180
        let a = sin(latitudeDelta / 2) * sin(latitudeDelta / 2)
            + cos(latitude1) * cos(latitude2)
            * sin(longitudeDelta / 2) * sin(longitudeDelta / 2)
        return earthRadius * 2 * atan2(sqrt(a), sqrt(1 - a))
    }
}
