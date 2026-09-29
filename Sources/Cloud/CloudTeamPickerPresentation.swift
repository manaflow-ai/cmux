import Observation

/// Transient presentation owned by one Cloud surface, separate from team selection.
@MainActor
@Observable
final class CloudTeamPickerPresentation {
    var isPresented = false
}
