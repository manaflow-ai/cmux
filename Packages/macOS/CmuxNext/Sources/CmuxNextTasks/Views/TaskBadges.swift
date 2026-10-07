import CmuxAgentBrands
import SwiftUI

/// A person's initial, or an agent mark with its harness initial.
struct AssigneeBadge: View {
    let assignee: TaskPrincipal?
    let delegate: TaskAgent?
    var size: CGFloat = 18
    @Environment(\.tasksColors) private var colors

    var body: some View {
        if let delegate {
            ZStack {
                RoundedRectangle(cornerRadius: size * 0.3).fill(colors.ansi(5).opacity(0.22))
                AgentBrandMark(agent: delegate.harness, size: size * 0.62).foregroundStyle(colors.ansi(5))
            }
            .frame(width: size, height: size)
            .help(delegate.harness)
        } else if let assignee {
            ZStack {
                Circle().fill(colors.hover)
                Text(assignee.shortName.prefix(1).uppercased())
                    .font(.system(size: size * 0.5, weight: .semibold)).foregroundStyle(colors.secondary)
            }
            .frame(width: size, height: size)
            .help(assignee.shortName)
        } else {
            Circle().strokeBorder(colors.tertiary.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                .frame(width: size, height: size)
                .help(TasksStrings.unassigned)
        }
    }
}

/// Labels as colored dots; names on hover (minimal labels).
struct LabelDots: View {
    let labels: [TaskLabelItem]
    @Environment(\.tasksColors) private var colors

    var body: some View {
        HStack(spacing: 3) {
            ForEach(labels) { label in
                Circle().fill(colors.ansi(label.color)).frame(width: 6, height: 6).help(label.name)
            }
        }
    }
}

/// Labels as small text chips (board cards, detail).
struct LabelChips: View {
    let labels: [TaskLabelItem]
    @Environment(\.tasksColors) private var colors

    var body: some View {
        HStack(spacing: 4) {
            ForEach(labels) { label in
                HStack(spacing: 3) {
                    Circle().fill(colors.ansi(label.color)).frame(width: 5, height: 5)
                    Text(label.name).font(.system(size: 10.5)).foregroundStyle(colors.secondary)
                }
                .padding(.horizontal, 5).padding(.vertical, 1.5)
                .background(Capsule().strokeBorder(colors.separator))
            }
        }
    }
}
