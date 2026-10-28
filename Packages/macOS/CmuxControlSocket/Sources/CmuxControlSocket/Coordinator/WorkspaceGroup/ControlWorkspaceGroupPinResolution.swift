public import Foundation

/// The outcome of `workspace.group.pin` / `.unpin`.
///
/// The legacy body reported success whenever the group existed, even when the
/// app refused the change (a protected group such as Chief Home stays pinned),
/// so the CLI printed `OK` for an unpin that did nothing.
public enum ControlWorkspaceGroupPinResolution: Sendable, Equatable {
    /// No TabManager resolved (legacy `unavailable` / "TabManager not
    /// available").
    case tabManagerUnavailable
    /// The group was not found (legacy `not_found` / "Group not found").
    case notFound
    /// The app refused the change. Carries the app's localized reason.
    case protected(message: String)
    /// The group now has the requested pinned state.
    case applied
}
