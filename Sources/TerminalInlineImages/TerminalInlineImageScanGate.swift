import Foundation

/// Admits one inline-image scan at a time and coalesces a burst into one follow-up scan.
struct TerminalInlineImageScanGate: Sendable {
    private var inFlightID: UUID?
    private(set) var hasPendingScan = false

    var isIdle: Bool {
        inFlightID == nil && !hasPendingScan
    }

    mutating func requestScan() -> UUID? {
        guard inFlightID == nil else {
            hasPendingScan = true
            return nil
        }
        let id = UUID()
        inFlightID = id
        return id
    }

    mutating func completeScan(_ id: UUID) -> UUID? {
        guard inFlightID == id else { return nil }
        guard hasPendingScan else {
            inFlightID = nil
            return nil
        }
        hasPendingScan = false
        let nextID = UUID()
        inFlightID = nextID
        return nextID
    }

    mutating func discardPendingScan() {
        hasPendingScan = false
    }

    mutating func cancelScan(_ id: UUID) {
        guard inFlightID == id else { return }
        inFlightID = nil
        hasPendingScan = false
    }
}
