import Foundation

/// Which team a control-plane request is authorized against.
///
/// A signed-in user can hold open Cloud surfaces from several teams at once.
/// Each request names the team that owns its target; the server verifies the
/// user's membership in that team per request.
enum VMRequestTeamBinding: Sendable, Equatable {
    /// The currently selected team. The request fails if the selection
    /// changes before it completes, so an old team's result is never published
    /// into the new team's views.
    case selected
    /// The team that owns the target resource, captured when the surface was
    /// created. A selection change does not cancel the request.
    case owner(String)
    /// A user-scoped request (tunnel enrollment). The selected team header is
    /// still sent for older servers, but a selection change does not cancel it.
    case user

    /// Normalizes an optional explicit team: nil or blank means ``selected``.
    init(explicitTeamID: String?) {
        let trimmed = explicitTeamID?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmed, !trimmed.isEmpty {
            self = .owner(trimmed)
        } else {
            self = .selected
        }
    }

    /// The owning team for ``owner(_:)``; nil otherwise.
    var explicitTeamID: String? {
        if case .owner(let teamID) = self { return teamID }
        return nil
    }

    /// Whether a change of the selected team cancels the request.
    var followsSelectedTeam: Bool { self == .selected }
}
