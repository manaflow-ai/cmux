import SwiftUI

/// Why a task needs attention, as a colored dot.
struct AttentionDot: View {
    let attention: TaskAttention?
    @Environment(\.tasksColors) private var colors

    var body: some View {
        if let attention {
            Circle().fill(color(attention)).frame(width: 7, height: 7)
                .help(label(attention))
        }
    }

    private func color(_ attention: TaskAttention) -> Color {
        switch attention {
        case .needsInput: colors.attention
        case .failed: colors.danger
        case .review: colors.success
        }
    }

    private func label(_ attention: TaskAttention) -> String {
        switch attention {
        case .needsInput: TasksStrings.needsInput
        case .failed: TasksStrings.failed
        case .review: TasksStrings.review
        }
    }
}
