import AppKit
import SwiftUI

/// The owner never answered: say so and show the command that starts it.
/// The app does not start the owner itself yet (daemon supervision is a
/// later slice), so the pane only explains.
struct OwnerNotRunningView: View {
    @Environment(\.tasksColors) private var colors

    static let command = "cmux task serve"

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "checklist").font(.system(size: 26, weight: .light)).foregroundStyle(colors.tertiary)
            Text(TasksStrings.ownerNotRunningTitle).font(.system(size: 14, weight: .semibold)).foregroundStyle(colors.primary)
            Text(TasksStrings.ownerNotRunningHint).font(.system(size: 12)).foregroundStyle(colors.secondary)
            HStack(spacing: 8) {
                Text(Self.command).font(.system(size: 12, design: .monospaced)).foregroundStyle(colors.primary)
                    .textSelection(.enabled)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(Self.command, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc").font(.system(size: 11))
                }
                .buttonStyle(.plain).foregroundStyle(colors.secondary)
                .help(TasksStrings.copyCommand)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 7).fill(colors.hover))
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// My Tasks narrows the layouts; this bar names the scope and widens it.
struct ScopeBar: View {
    let model: TasksModel
    @Environment(\.tasksColors) private var colors

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "person").font(.system(size: 11)).foregroundStyle(colors.tertiary)
            Text(TasksStrings.mine).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(colors.secondary)
            Spacer()
            Button(TasksStrings.showAll) { model.scope = .all }
                .buttonStyle(.plain).font(.system(size: 11.5)).foregroundStyle(colors.secondary)
        }
        .padding(.horizontal, 14).padding(.vertical, 6)
        .overlay(alignment: .bottom) { Rectangle().fill(colors.separator).frame(height: 1) }
    }
}
