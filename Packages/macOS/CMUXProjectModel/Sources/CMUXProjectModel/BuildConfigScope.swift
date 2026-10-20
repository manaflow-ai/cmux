import Foundation

/// Where a ``BuildConfigSummary`` is attached.
///
/// Build settings live in two places in an Xcode project: at the project
/// level (inherited by every target) and at the target level (overrides). The
/// scope identifies which side of the inheritance stack a particular config
/// row belongs to so the Levels view can render it in the correct column.
public enum BuildConfigScope: Sendable, Hashable {
    case project
    case target(TargetID)
}
