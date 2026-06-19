public import Foundation

/// The outcome of an open-or-focus surface lookup: either an existing surface
/// already shows the requested content (and may need focusing) or a new
/// surface must be created.
public enum SurfaceReuseDecision: Sendable, Equatable {
    /// An existing panel already shows the requested content.
    ///
    /// - Parameters:
    ///   - panelId: the matched panel's workspace-registry identifier.
    ///   - shouldFocus: whether the caller should move focus to it. The split
    ///     entry points always focus the reused surface; the in-pane entry
    ///     points only focus when their `focus` argument is set.
    case focusExisting(panelId: UUID, shouldFocus: Bool)

    /// No existing surface matches; the caller must create a new one.
    case create
}
