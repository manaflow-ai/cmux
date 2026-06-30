import SwiftUI

struct WorkspaceTaskInsertionDividerView: View {
    enum Style {
        case leadingDrop
        case hoverInsert
        case append
    }

    let style: Style
    let isActive: Bool
    let allowsAdd: Bool
    @Binding var draft: String
    let activate: () -> Void
    let cancel: () -> Void
    let submit: () -> Void
    let dropTask: (String) -> Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    var body: some View {
        VStack(spacing: 6) {
            if isActive {
                activeComposer
                .transition(.opacity.combined(with: .move(edge: .top)))
            } else if style == .append {
                appendButton
            } else {
                hoverZone
            }
        }
        .dropDestination(for: String.self) { dropped, _ in
            guard let taskId = dropped.first else { return false }
            return dropTask(taskId)
        }
    }

    private var activeComposer: some View {
        HStack(spacing: 8) {
            WorkspaceTaskAddComposer(
                draft: $draft,
                placeholder: composerPlaceholder,
                submitLabel: composerSubmitLabel,
                autoFocus: true,
                submit: submit
            )
            Button(action: cancel) {
                CmuxSystemSymbolImage(magnified: "xmark", pointSize: 12)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .help(composerCancelLabel)
            .accessibilityLabel(composerCancelLabel)
        }
        .padding(.vertical, 2)
    }

    private var appendButton: some View {
        Button(action: activate) {
            HStack(spacing: 8) {
                CmuxSystemSymbolImage(magnified: "plus", pointSize: 12, weight: .medium)
                    .foregroundStyle(taskAccent)
                    .frame(width: 18, height: 18)
                Text(String(localized: "workspaceTasks.add.label", defaultValue: "Add task"))
                    .cmuxFont(size: 13, weight: .regular)
                    .foregroundStyle(isHovering ? taskAccent : Color.secondary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 2)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, minHeight: 38)
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(isHovering ? 0.48 : 0))
        )
        .help(String(localized: "workspaceTasks.add.label", defaultValue: "Add task"))
        .accessibilityLabel(String(localized: "workspaceTasks.add.label", defaultValue: "Add task"))
        .onHover { isHovering = $0 }
        .animation(hoverAnimation, value: isHovering)
    }

    @ViewBuilder
    private var hoverZone: some View {
        if allowsAdd {
            insertHoverButton
        } else {
            dropOnlyZone
        }
    }

    private var insertHoverButton: some View {
        Button(action: activate) {
            ZStack {
                Rectangle()
                    .fill(Color.clear)
                Rectangle()
                    .fill(taskAccent.opacity(isHovering ? 0.34 : 0))
                    .frame(height: 1)
                CmuxSystemSymbolImage(magnified: "plus", pointSize: 11, weight: .semibold)
                    .foregroundStyle(taskAccent)
                    .frame(width: 20, height: 20)
                    .background(.thinMaterial, in: Capsule())
                    .overlay {
                        Capsule()
                            .stroke(taskAccent.opacity(0.22), lineWidth: 1)
                    }
                    .opacity(isHovering ? 1 : 0)
                    .scaleEffect(isHovering ? 1 : 0.9)
            }
            .frame(maxWidth: .infinity, minHeight: 18)
        }
        .buttonStyle(.plain)
        .help(String(localized: "workspaceTasks.insert.help", defaultValue: "Insert task here"))
        .accessibilityLabel(String(localized: "workspaceTasks.insert.label", defaultValue: "Insert Task Here"))
        .onHover { isHovering = $0 }
        .animation(hoverAnimation, value: isHovering)
    }

    private var dropOnlyZone: some View {
        ZStack {
            Rectangle()
                .fill(Color.clear)
            Rectangle()
                .fill(taskAccent.opacity(isHovering ? 0.24 : 0))
                .frame(height: 1)
        }
        .frame(maxWidth: .infinity, minHeight: 8)
        .onHover { isHovering = $0 }
        .accessibilityHidden(true)
        .animation(hoverAnimation, value: isHovering)
    }

    private var hoverAnimation: Animation? {
        reduceMotion ? nil : .easeOut(duration: 0.12)
    }

    private var taskAccent: Color {
        Color(red: 0.86, green: 0.25, blue: 0.19)
    }

    private var composerPlaceholder: String {
        switch style {
        case .append:
            String(localized: "workspaceTasks.add.placeholder", defaultValue: "Add a task")
        case .leadingDrop, .hoverInsert:
            String(localized: "workspaceTasks.insert.placeholder", defaultValue: "Insert a task")
        }
    }

    private var composerSubmitLabel: String {
        switch style {
        case .append:
            String(localized: "workspaceTasks.add.label", defaultValue: "Add task")
        case .leadingDrop, .hoverInsert:
            String(localized: "workspaceTasks.insert.submit", defaultValue: "Insert task")
        }
    }

    private var composerCancelLabel: String {
        switch style {
        case .append:
            String(localized: "workspaceTasks.add.cancel", defaultValue: "Cancel add")
        case .leadingDrop, .hoverInsert:
            String(localized: "workspaceTasks.insert.cancel", defaultValue: "Cancel insert")
        }
    }
}
