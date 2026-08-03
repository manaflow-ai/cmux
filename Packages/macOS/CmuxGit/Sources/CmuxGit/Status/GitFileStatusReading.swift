import Foundation

/// Reads status metadata for a filesystem path.
protocol GitFileStatusReading: Sendable {
    func status(atPath path: String) -> GitIndexFileStatus?
}
