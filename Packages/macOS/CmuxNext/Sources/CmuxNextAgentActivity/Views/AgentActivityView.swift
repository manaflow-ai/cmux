import AppKit
import SwiftUI

/// Root of the pane. The layout comes from the Debug Settings prototype
/// switch (`agentActivity.layout`); Release always shows `split`.
struct AgentActivityView: View {
    @Environment(\.agentActivityColors) private var colors
    let model: AgentActivityModel
    var layout: AgentActivityLayout = AgentActivityTunables.layout.value

    var body: some View {
        Group {
            if model.allSessions.isEmpty && model.connections.isEmpty {
                AgentActivityEmptyView()
            } else {
                switch layout {
                case .split: AgentActivitySplitView(model: model)
                case .timeline: AgentActivityLanesView(model: model)
                case .grid: AgentActivityGridView(model: model)
                }
            }
        }
        .background(colors.background)
        .foregroundStyle(colors.primary)
    }
}

struct AgentActivityEmptyView: View {
    @Environment(\.agentActivityColors) private var colors
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "cursorarrow.click.2")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(colors.tertiary)
            Text(AgentActivityStrings.emptyTitle).font(.system(size: 15, weight: .semibold))
            Text(AgentActivityStrings.emptyDetail)
                .font(.system(size: 12))
                .foregroundStyle(colors.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
