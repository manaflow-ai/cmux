import Foundation
import CmuxWorkspaces

/// One remembered window frame for a specific display configuration. A window
/// keeps a small LRU ring of these so it can return to where it was on each
/// monitor arrangement the user switches between (issue #2135).
struct SessionConfigFrameEntry: Codable, Sendable, Equatable {
    /// The display-configuration signature this frame belongs to
    /// (see `DisplayConfigurationSignature`).
    var signature: String
    var frame: SessionRectSnapshot
    var display: SessionDisplaySnapshot?
    /// Wall-clock of the last capture, for LRU eviction.
    var lastUsedAt: TimeInterval
}
