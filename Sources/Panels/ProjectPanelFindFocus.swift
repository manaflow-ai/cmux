import Foundation
import Observation

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
final class ProjectPanelFindFocus {
    /// The filter field that should receive focus, or `nil` when no request is pending.
    var request: ProjectPanelTab?

    /// Incremented to ask the active filter field to resign first-responder.
    var resignToken: Int = 0

    init() {}
}
