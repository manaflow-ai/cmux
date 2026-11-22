import SwiftUI

/// Status as a drawn glyph in the status's palette color: dashed ring
/// (triage), dotted ring (backlog), ring (unstarted), half disc (started),
/// filled check (completed), crossed disc (canceled).
struct StatusGlyph: View {
    let category: TaskCategory
    let color: Color
    var size: CGFloat = 12
    @Environment(\.tasksColors) private var colors

    var body: some View {
        ZStack {
            switch category {
            case .triage:
                Circle().strokeBorder(color, style: StrokeStyle(lineWidth: 1.4, dash: [2.2, 1.6]))
            case .backlog:
                Circle().strokeBorder(color, style: StrokeStyle(lineWidth: 1.4, dash: [0.8, 1.8]))
            case .unstarted:
                Circle().strokeBorder(color, lineWidth: 1.4)
            case .started:
                Circle().strokeBorder(color, lineWidth: 1.4)
                HalfDisc().fill(color).padding(size * 0.22)
            case .completed:
                Circle().fill(color)
                Image(systemName: "checkmark").font(.system(size: size * 0.55, weight: .bold)).foregroundStyle(colors.background)
            case .canceled:
                Circle().fill(color.opacity(0.7))
                Image(systemName: "xmark").font(.system(size: size * 0.5, weight: .bold)).foregroundStyle(colors.background)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

private nonisolated struct HalfDisc: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        path.move(to: center)
        path.addArc(center: center, radius: rect.width / 2, startAngle: .degrees(-90), endAngle: .degrees(90), clockwise: false)
        path.closeSubpath()
        return path
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
