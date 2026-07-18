#if DEBUG
import SwiftUI

/// Supplies Signal's redundant word, symbol, meaning, and fixed color for one state.
struct SignalStatusStyle {
    let state: GalleryAgentState
    let label: String
    let compactLabel: String
    let symbol: String
    let meaning: String
    let color: Color

    init(state: GalleryAgentState, theme: SignalTheme) {
        self.state = state
        color = theme.color(for: state)

        switch state {
        case .needsYou:
            label = "NEEDS YOU"
            compactLabel = "NEEDS"
            symbol = "!"
            meaning = "Waiting for a decision"
        case .failed:
            label = "FAILED"
            compactLabel = "FAILED"
            symbol = "×"
            meaning = "Stopped with an error"
        case .running:
            label = "RUNNING"
            compactLabel = "RUN"
            symbol = "→"
            meaning = "Actively working"
        case .done:
            label = "DONE"
            compactLabel = "DONE"
            symbol = "✓"
            meaning = "Completed successfully"
        case .idle:
            label = "IDLE"
            compactLabel = "IDLE"
            symbol = "–"
            meaning = "No recent activity"
        }
    }

    /// Indicates whether another fixture state occupies this style's taxonomy slot.
    func matches(_ other: GalleryAgentState) -> Bool {
        switch (state, other) {
        case (.needsYou, .needsYou), (.failed, .failed), (.running, .running),
             (.done, .done), (.idle, .idle):
            true
        default:
            false
        }
    }

    /// Indicates whether the status uses Signal's running shimmer.
    var isRunning: Bool {
        if case .running = state { true } else { false }
    }
}
#endif
