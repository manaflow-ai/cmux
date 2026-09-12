internal import Foundation

/// Validated intent for a configuration reload, separate from persistent queue edits.
public struct ControlConfigurationReloadRequest: Equatable, Sendable {
    /// Whether to explicitly select the first video-background queue entry after commit.
    public let restartVideoBackground: Bool

    /// Accepts an ordinary reload or an explicit video-background selection.
    public init?(arguments: String) {
        switch arguments.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "": restartVideoBackground = false
        case "--restart-video-background": restartVideoBackground = true
        default: return nil
        }
    }
}
