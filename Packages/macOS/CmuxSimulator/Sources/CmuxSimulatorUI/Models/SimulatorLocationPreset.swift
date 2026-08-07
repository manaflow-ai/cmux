import CmuxSimulator

// Route coordinates are adapted from serve-sim commit
// af681b8c3b0453f31dcb8e98a3389f23b7cfc6b0 (Apache-2.0).
// The source coordinates were sampled from OpenStreetMap data under ODbL.
// Modified by cmux for direct native simctl route playback; attribution is in
// the Simulator worker's bundled third-party notices.
enum SimulatorLocationPreset: String, CaseIterable, Identifiable {
    case applePark
    case goldenGate
    case mountTam
    case centralPark
    case pacificCoast

    var id: String { rawValue }

    var defaultMode: SimulatorLocationTransportMode {
        switch self {
        case .applePark, .mountTam: .walk
        case .goldenGate, .centralPark: .run
        case .pacificCoast: .drive
        }
    }

    var closedWaypoints: [SimulatorLocationCoordinate] {
        guard let first = waypoints.first else { return [] }
        return waypoints + [first]
    }

    private var waypoints: [SimulatorLocationCoordinate] {
        switch self {
        case .applePark:
            simulatorLocationCoordinates([
                (37.33272, -122.00833), (37.33309, -122.00735),
                (37.33373, -122.00663), (37.33454, -122.00627),
                (37.33540, -122.00633), (37.33618, -122.00679),
                (37.33675, -122.00759), (37.33704, -122.00861),
                (37.33698, -122.00969), (37.33662, -122.01066),
                (37.33598, -122.01138), (37.33517, -122.01174),
                (37.33431, -122.01169), (37.33354, -122.01122),
                (37.33296, -122.01042), (37.33268, -122.00940),
            ])
        case .goldenGate:
            simulatorLocationCoordinates([
                (37.83212, -122.48065), (37.82937, -122.47974),
                (37.82649, -122.47940), (37.82362, -122.47907),
                (37.82074, -122.47873), (37.81786, -122.47839),
                (37.81498, -122.47806), (37.81211, -122.47772),
                (37.80923, -122.47734), (37.80949, -122.47730),
                (37.81236, -122.47765), (37.81524, -122.47798),
                (37.81812, -122.47832), (37.82100, -122.47866),
                (37.82387, -122.47900), (37.82675, -122.47933),
                (37.82963, -122.47967), (37.83233, -122.48072),
            ])
        case .mountTam:
            simulatorLocationCoordinates([
                (37.88664, -122.62599), (37.88887, -122.62332),
                (37.89115, -122.62160), (37.89353, -122.61921),
                (37.89466, -122.61577), (37.89631, -122.61268),
                (37.89917, -122.61098), (37.90166, -122.60855),
                (37.90199, -122.60601), (37.90339, -122.60401),
                (37.90662, -122.60291), (37.90971, -122.60173),
                (37.91213, -122.60007), (37.91439, -122.59780),
                (37.91285, -122.59504), (37.91274, -122.59202),
                (37.91500, -122.59032), (37.91637, -122.58903),
                (37.91481, -122.58595), (37.91740, -122.58398),
                (37.91642, -122.58236), (37.91481, -122.58011),
            ])
        case .centralPark:
            simulatorLocationCoordinates([
                (40.78216, -73.96254), (40.78221, -73.96098),
                (40.78328, -73.96010), (40.78440, -73.95930),
                (40.78550, -73.95848), (40.78664, -73.95774),
                (40.78790, -73.95764), (40.78898, -73.95792),
                (40.78868, -73.95951), (40.78897, -73.96112),
                (40.78833, -73.96250), (40.78828, -73.96416),
                (40.78805, -73.96573), (40.78691, -73.96636),
                (40.78566, -73.96665), (40.78458, -73.96608),
                (40.78402, -73.96459), (40.78322, -73.96334),
            ])
        case .pacificCoast:
            simulatorLocationCoordinates([
                (37.59659, -122.50316), (37.59555, -122.50424),
                (37.59452, -122.50534), (37.59329, -122.50588),
                (37.59212, -122.50508), (37.59100, -122.50413),
                (37.58974, -122.50416), (37.58870, -122.50524),
                (37.58745, -122.50496), (37.58627, -122.50422),
                (37.58539, -122.50534), (37.58505, -122.50698),
                (37.58539, -122.50534), (37.58627, -122.50422),
                (37.58745, -122.50496), (37.58870, -122.50524),
                (37.58974, -122.50416), (37.59100, -122.50413),
                (37.59212, -122.50508), (37.59329, -122.50588),
                (37.59452, -122.50534), (37.59555, -122.50424),
            ])
        }
    }

}

private func simulatorLocationCoordinates(
    _ values: [(Double, Double)]
) -> [SimulatorLocationCoordinate] {
    values.map { SimulatorLocationCoordinate(latitude: $0.0, longitude: $0.1) }
}
