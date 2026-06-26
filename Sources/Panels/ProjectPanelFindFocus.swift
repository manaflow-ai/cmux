import Foundation
import Observation

/// Identifies which ``ProjectPanel`` filter field a find request targets.
public enum ProjectPanelSearchFocus: Hashable, Sendable {
    case files
    case settings
}

/// Lightweight, view-observable find-focus state for a ``ProjectPanel``.
///
/// The tab views drive their `@FocusState` from these signals: ``request``
/// moves keyboard focus into a filter field (cleared by the view once applied),
/// and ``resignToken`` bumps to pull focus back out for "Hide Find Bar".
///
/// Kept on a separate `@Observable` object — rather than as another `@Published`
/// property on the legacy `ObservableObject` ``ProjectPanel`` — so the
/// find-focus state follows the modern value-snapshot shape and does not
/// broaden the panel's Combine invalidation.
@MainActor
@Observable
public final class ProjectPanelFindFocus {
    /// The filter field that should receive focus, or `nil` when no request is pending.
    public var request: ProjectPanelSearchFocus?

    /// Incremented to ask the active filter field to resign first-responder.
    public var resignToken: Int = 0

    public init() {}
}
