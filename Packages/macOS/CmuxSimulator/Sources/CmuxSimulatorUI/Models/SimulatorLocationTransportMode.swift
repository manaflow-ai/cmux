enum SimulatorLocationTransportMode: String, CaseIterable, Identifiable {
    case walk
    case run
    case cycle
    case drive

    var id: String { rawValue }

    var metersPerSecond: Double {
        switch self {
        case .walk: 1.4
        case .run: 3.0
        case .cycle: 5.5
        case .drive: 13.4
        }
    }
}
