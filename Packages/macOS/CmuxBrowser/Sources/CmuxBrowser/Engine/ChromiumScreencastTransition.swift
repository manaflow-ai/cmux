/// Describes the one CDP command needed to reconcile Chromium frame delivery
/// with the pane's current visibility.
struct ChromiumScreencastTransition: Equatable, Sendable {
    let isPaneVisible: Bool
    let isScreencastActive: Bool

    /// The transition command, or `nil` when the desired and actual states
    /// already agree.
    var method: String? {
        guard isPaneVisible != isScreencastActive else { return nil }
        return isPaneVisible ? "Page.startScreencast" : "Page.stopScreencast"
    }
}
