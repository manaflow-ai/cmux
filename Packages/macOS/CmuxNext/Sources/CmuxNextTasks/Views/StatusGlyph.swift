import CmuxNextIcons
import SwiftUI

/// Status as the pack's task status icon in the status's palette color: dashed ring (triage),
/// dotted ring (backlog), ring (unstarted), half disc (started), check (completed), cross
/// (canceled).
struct StatusGlyph: View {
    let category: TaskCategory
    let color: Color
    var size: CGFloat = 12

    var body: some View {
        Icon(icon, size: size)
            .foregroundStyle(category == .canceled ? color.opacity(0.7) : color)
            .accessibilityHidden(true)
    }

    private var icon: IconName {
        switch category {
        case .triage: .taskStatusTriage
        case .backlog: .taskStatusBacklog
        case .unstarted: .taskStatusTodo
        case .started: .taskStatusStarted
        case .completed: .taskStatusDone
        case .canceled: .taskStatusCanceled
        }
    }
}
