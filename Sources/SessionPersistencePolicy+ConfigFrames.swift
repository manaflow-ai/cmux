import Foundation

extension SessionPersistencePolicy {
    /// Maximum number of per-display-configuration frames a window remembers.
    /// An LRU ring evicts the least-recently-used configuration past this cap.
    static let maxConfigFramesPerWindow: Int = 8
}
