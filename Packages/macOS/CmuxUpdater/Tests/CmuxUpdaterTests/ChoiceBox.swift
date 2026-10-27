@testable import CmuxUpdater

/// Captures the `reply` sent to one "Update Available" prompt.
final class ChoiceBox: @unchecked Sendable {
    var choice: UpdateChoice?
}
