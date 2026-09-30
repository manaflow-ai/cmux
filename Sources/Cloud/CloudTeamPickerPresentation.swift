import Observation

/// Transient presentation owned by one Cloud surface, separate from team selection.
@MainActor
@Observable
final class CloudTeamPickerPresentation {
    var isPresented = false
    /// The Invite popover anchored to the header Invite button.
    var isInvitePresented = false
}
