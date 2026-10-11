import SwiftUI

/// An agent session's plan as a thin progress bar plus its status word.
struct PlanProgress: View {
    let session: TaskSessionItem
    @Environment(\.tasksColors) private var colors

    var body: some View {
        let done = session.plan.filter { $0.status == "completed" }.count
        HStack(spacing: 6) {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(colors.hover)
                    Capsule().fill(colors.ansi(5))
                        .frame(width: proxy.size.width * CGFloat(done) / CGFloat(max(session.plan.count, 1)))
                }
            }
            .frame(height: 3)
            Text(TasksStrings.session(session.status)).font(.system(size: 10.5)).foregroundStyle(colors.tertiary)
        }
    }
}
