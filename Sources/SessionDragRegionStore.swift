import Foundation

/// Immutable row hit regions consumed by an AppKit Vault drag monitor.
@MainActor
final class SessionDragRegionStore {
    struct Region: Equatable {
        let rowID: SessionIndexRowSnapshot.ID
        let entry: SessionEntry
        let frame: CGRect
    }

    private var regionsByID: [SessionIndexRowSnapshot.ID: Region] = [:]

    func update(_ row: SessionIndexRowSnapshot, frame: CGRect?) {
        guard let frame, frame.width > 0, frame.height > 0 else {
            regionsByID[row.id] = nil
            return
        }
        regionsByID[row.id] = Region(
            rowID: row.id,
            entry: row.entry,
            frame: frame
        )
    }

    func remove(_ rowID: SessionIndexRowSnapshot.ID) {
        regionsByID[rowID] = nil
    }

    func region(at point: CGPoint) -> Region? {
        regionsByID.values
            .filter { $0.frame.contains(point) }
            .min { lhs, rhs in
                (lhs.frame.width * lhs.frame.height) < (rhs.frame.width * rhs.frame.height)
            }
    }
}
