import SwiftUI

struct WorkspaceTaskInsertionDividerView: View {
    let isActive: Bool
    @Binding var draft: String
    let activate: () -> Void
    let cancel: () -> Void
    let submit: () -> Void

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Rectangle()
                    .fill(Color(nsColor: .separatorColor).opacity(0.45))
                    .frame(height: 1)
                Button(action: activate) {
                    Image(systemName: "plus.circle.fill")
                        .cmuxSymbolRasterSize(14)
                        .frame(width: 22, height: 18)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(String(localized: "workspaceTasks.insert.help", defaultValue: "Insert task here"))
                .accessibilityLabel(String(localized: "workspaceTasks.insert.label", defaultValue: "Insert Task Here"))
                Rectangle()
                    .fill(Color(nsColor: .separatorColor).opacity(0.45))
                    .frame(height: 1)
            }
            .frame(height: 18)

            if isActive {
                HStack(spacing: 8) {
                    TextField(
                        String(localized: "workspaceTasks.insert.placeholder", defaultValue: "Insert a task"),
                        text: $draft
                    )
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(submit)
                    Button(action: submit) {
                        Image(systemName: "checkmark")
                            .cmuxSymbolRasterSize(13)
                            .frame(width: 24, height: 22)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!WorkspaceTask.isValidTitle(draft))
                    .help(String(localized: "workspaceTasks.insert.submit", defaultValue: "Insert task"))
                    .accessibilityLabel(String(localized: "workspaceTasks.insert.submit", defaultValue: "Insert task"))
                    Button(action: cancel) {
                        Image(systemName: "xmark")
                            .cmuxSymbolRasterSize(12)
                            .frame(width: 24, height: 22)
                    }
                    .buttonStyle(.plain)
                    .help(String(localized: "workspaceTasks.insert.cancel", defaultValue: "Cancel insert"))
                    .accessibilityLabel(String(localized: "workspaceTasks.insert.cancel", defaultValue: "Cancel insert"))
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}
