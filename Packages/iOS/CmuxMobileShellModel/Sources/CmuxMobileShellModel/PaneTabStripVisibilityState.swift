/// Pure visibility reducer for the in-pane tab strip.
public struct PaneTabStripVisibilityState: Equatable, Sendable {
    /// Events that can change strip visibility.
    public enum Event: Equatable, Sendable {
        /// A pane became the full-screen destination.
        case enteredPane
        /// The focused terminal produced the user's first input.
        case terminalKeystroke
        /// The terminal's native scroll gesture began.
        case terminalScrollBegan
        /// The persistent handle was tapped.
        case handleTapped
        /// The persistent handle was dragged upward.
        case handleDraggedUp
    }

    /// The reduced presentation state.
    public private(set) var isStripVisible: Bool

    /// Creates visibility state. Entering a pane defaults to a visible strip.
    /// - Parameter isStripVisible: The initial presentation, normally `true`.
    public init(isStripVisible: Bool = true) {
        self.isStripVisible = isStripVisible
    }

    /// Applies one explicit interaction event.
    /// - Parameter event: The event to reduce.
    public mutating func handle(_ event: Event) {
        switch event {
        case .enteredPane, .handleTapped, .handleDraggedUp:
            isStripVisible = true
        case .terminalKeystroke, .terminalScrollBegan:
            isStripVisible = false
        }
    }
}
