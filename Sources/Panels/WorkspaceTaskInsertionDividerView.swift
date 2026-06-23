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
                placeholder: String(localized: "workspaceTasks.insert.placeholder", defaultValue: "Insert a task"),
                submitLabel: String(localized: "workspaceTasks.insert.submit", defaultValue: "Insert task"),
                autoFocus: true,
                submit: submit
            )
            Button(action: cancel) {
                Image(systemName: "xmark")
                    .cmuxSymbolRasterSize(12)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .help(String(localized: "workspaceTasks.insert.cancel", defaultValue: "Cancel insert"))
            .accessibilityLabel(String(localized: "workspaceTasks.insert.cancel", defaultValue: "Cancel insert"))
        }
    }

    private var appendButton: some View {
        Button(action: activate) {
            HStack(spacing: 8) {
                Image(systemName: "plus.circle.fill")
                    .cmuxSymbolRasterSize(14)
                Text(String(localized: "workspaceTasks.add.label", defaultValue: "Add task"))
                    .cmuxFont(size: 12, weight: .semibold)
            }
            .frame(maxWidth: .infinity, minHeight: 34)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(isHovering ? 0.86 : 0.5))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(
                    Color(nsColor: .separatorColor).opacity(isHovering ? 0.6 : 0.34),
                    style: StrokeStyle(lineWidth: 1, dash: [4, 4])
                )
        }
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
                    .fill(Color.accentColor.opacity(isHovering ? 0.32 : 0))
                    .frame(height: 1)
                Image(systemName: "plus.circle.fill")
                    .cmuxSymbolRasterSize(14)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(.thinMaterial, in: Capsule())
                    .opacity(isHovering ? 1 : 0)
                    .scaleEffect(isHovering ? 1 : 0.92)
            }
            .frame(maxWidth: .infinity, minHeight: 22)
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
                .fill(Color.accentColor.opacity(isHovering ? 0.28 : 0))
                .frame(height: 1)
        }
        .frame(maxWidth: .infinity, minHeight: 10)
        .onHover { isHovering = $0 }
        .accessibilityHidden(true)
        .animation(hoverAnimation, value: isHovering)
    }

    private var hoverAnimation: Animation? {
        reduceMotion ? nil : .easeOut(duration: 0.12)
    }
}
