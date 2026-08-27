@MainActor
struct WorkspacePaletteColorReconcileTracker {
    private var trackedHexes: [String: String]?
    private var revisions: [String: Int] = [:]

    func revision(for name: String) -> Int {
        revisions[name, default: 0]
    }

    mutating func startTracking(_ hexes: [String: String]) {
        if trackedHexes == nil {
            trackedHexes = hexes
        }
    }

    mutating func recordPickerWrite(name: String, resultingHexes: [String: String]) {
        trackedHexes = resultingHexes
        bump(name)
    }

    mutating func recordPaletteReset(resultingHexes: [String: String]) {
        let affectedNames = Set((trackedHexes ?? [:]).keys).union(resultingHexes.keys)
        trackedHexes = resultingHexes
        for name in affectedNames {
            bump(name)
        }
    }

    mutating func reconcileExternalHexes(_ hexes: [String: String]) {
        guard let previousHexes = trackedHexes else {
            trackedHexes = hexes
            return
        }

        let affectedNames = Set(previousHexes.keys).union(hexes.keys).filter { name in
            previousHexes[name] != hexes[name]
        }
        trackedHexes = hexes
        for name in affectedNames {
            bump(name)
        }
    }

    private mutating func bump(_ name: String) {
        revisions[name, default: 0] &+= 1
    }
}
