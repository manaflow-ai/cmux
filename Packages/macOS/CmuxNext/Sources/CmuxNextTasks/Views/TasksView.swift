import SwiftUI

/// The pane: one of three prototype layouts over the same model.
struct TasksView: View {
    let model: TasksModel
    let layout: TasksLayout
    @Environment(\.tasksColors) private var colors

    var body: some View {
        VStack(spacing: 0) {
            if model.neverConnected, case .disconnected = model.connection {
                OwnerNotRunningView()
            } else {
                if case let .disconnected(reason) = model.connection {
                    OwnerBanner(text: reason)
                }
                if model.scope == .mine {
                    ScopeBar(model: model)
                }
                NewTaskField(model: model)
                switch layout {
                case .list: TasksListView(model: model)
                case .board: TasksBoardView(model: model)
                case .inbox: TasksInboxView(model: model)
                }
            }
        }
        .background(colors.background)
        .overlay(alignment: .bottom) {
            if let reject = model.lastReject {
                Text(reject)
                    .font(.system(size: 11.5)).foregroundStyle(colors.primary)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 7).fill(colors.elevated).shadow(color: colors.shadow, radius: 8, y: 2))
                    .padding(12)
                    .transition(.opacity)
            }
        }
    }
}

/// The owner is unreachable: show it, and the model refuses changes.
private struct OwnerBanner: View {
    let text: String
    @Environment(\.tasksColors) private var colors

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(colors.attention).frame(width: 6, height: 6)
            Text(text).font(.system(size: 11.5)).foregroundStyle(colors.secondary)
            Spacer()
        }
        .padding(.horizontal, 14).padding(.vertical, 7)
        .background(colors.attention.opacity(0.08))
    }
}
