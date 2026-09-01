import Foundation

/// Immutable, size-bounded copy of one import source.
struct ArtifactSourceSnapshot {
    let url: URL
    let size: Int64
}
