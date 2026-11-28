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

/// Priority as signal bars (urgent is a filled square with "!").
struct PriorityGlyph: View {
    let priority: TaskPriority
    @Environment(\.tasksColors) private var colors

    var body: some View {
        Group {
            switch priority {
            case .none:
                Color.clear
            case .urgent:
                RoundedRectangle(cornerRadius: 2.5).fill(colors.attention)
                    .overlay(Text("!").font(.system(size: 9, weight: .heavy)).foregroundStyle(colors.background))
            case .high, .medium, .low:
                HStack(alignment: .bottom, spacing: 1.5) {
                    ForEach(0..<3, id: \.self) { bar in
                        RoundedRectangle(cornerRadius: 1)
                            .fill(bar < filled ? colors.secondary : colors.tertiary.opacity(0.35))
                            .frame(width: 2.5, height: CGFloat(4 + bar * 3))
                    }
                }
            }
        }
        .frame(width: 12, height: 12)
    }

    private var filled: Int {
        switch priority {
        case .high: 3
        case .medium: 2
        default: 1
        }
    }
}
