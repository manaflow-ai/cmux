import Foundation

/// A cheap stat-derived signature for the git index file.
struct GitIndexStatSignature: Equatable, Sendable {
    let size: Int64
    let mtimeSeconds: Int64
    let mtimeNanoseconds: Int64
}
