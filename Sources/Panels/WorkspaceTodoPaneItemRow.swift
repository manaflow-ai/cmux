import AppKit
import CmuxWorkspaces
import SwiftUI

struct WorkspaceTodoPaneItemRow: View {
    let item: WorkspaceChecklistItem
    let displayIndex: Int
    let isEditing: Bool
    let isHighlighted: Bool
    @Binding var editingText: String
    let editFieldFocused: FocusState<Bool>.Binding
    let itemFontSize: CGFloat
    let checkboxPointSize: CGFloat
    let actions: WorkspaceTodoPaneItemRowActions

    private var isCompleted: Bool { item.state == .completed }

    /// Distance above a text line's baseline to its optical vertical center
    /// (`(ascender + descender) / 2`), so the checkbox's
    /// `.alignmentGuide(.firstTextBaseline)` centers on the item text's FIRST
    /// line specifically — not the whole multi-line block, and not the
    /// baseline itself.
    private var firstLineCenterOffset: CGFloat {
        let font = NSFont.systemFont(ofSize: itemFontSize)
        return (font.ascender + font.descender) / 2
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Button {
                actions.toggleCompletion()
            } label: {
                CmuxSystemSymbolImage(
                    systemName: checkboxSymbolName(for: item.state),
                    pointSize: checkboxPointSize
                )
                .foregroundColor(isCompleted ? .secondary : .primary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + firstLineCenterOffset }
            .safeHelp(
                isCompleted
                    ? String(localized: "sidebar.checklist.uncheckTooltip", defaultValue: "Mark as pending")
                    : String(localized: "sidebar.checklist.checkTooltip", defaultValue: "Mark as completed")
            )
            if isEditing {
                TextField(
                    String(localized: "sidebar.checklist.editItemPlaceholder", defaultValue: "Item text"),
                    text: $editingText,
                    axis: .vertical
                )
                .textFieldStyle(.plain)
                .font(.system(size: itemFontSize))
                .foregroundColor(.primary)
                .focused(editFieldFocused)
                .lineLimit(1...8)
                .fixedSize(horizontal: false, vertical: true)
                .backport.onKeyPress(.return) { modifiers in
                    if modifiers.contains(.shift), modifiers.subtracting(.shift).isEmpty {
                        editingText.append("\n")
                        return .handled
                    }
                    if modifiers.contains(.command) {
                        actions.commitEdit()
                        return .handled
                    }
                    return .ignored
                }
                .onExitCommand(perform: actions.cancelEdit)
                .accessibilityIdentifier("WorkspaceTodoPaneEditItemField")
            } else {
                // No `lineLimit` — items wrap across multiple lines. Without
                // `.fixedSize(horizontal: false, ...)` Text can report its
                // ideal (unwrapped) single-line width as accepted inside this
                // HStack + Spacer + ScrollView nesting, so long items overflow
                // past the pane's edge instead of wrapping (see the sidebar's
                // matching fix in SidebarWorkspaceChecklistView.swift /
                // SidebarWorkspaceChecklistPopover.swift). The checkbox above
                // aligns to this Text's FIRST line only (`.firstTextBaseline`,
                // offset by `firstLineCenterOffset`), not the whole block.
                Text(item.text)
                    .font(.system(size: itemFontSize))
                    .foregroundColor(isCompleted ? .secondary : .primary)
                    .strikethrough(isCompleted)
                    .opacity(isCompleted ? 0.6 : 1)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .contentShape(Rectangle())
            }
            Spacer(minLength: 0)
            WorkspaceChecklistAttachmentMenu(
                item: item,
                iconPointSize: checkboxPointSize - 2,
                foregroundColor: .secondary,
                countFont: .system(size: itemFontSize - 1),
                addAttachments: { _ in actions.addAttachments() },
                removeAttachment: { _, attachmentId in actions.removeAttachment(attachmentId) },
                openAttachments: { _, selectedAttachmentId in actions.openAttachments(selectedAttachmentId) }
            )
            .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + firstLineCenterOffset }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(isHighlighted ? Color.primary.opacity(0.08) : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture { handleRowTap() }
        // Drag to reorder within the item's completion partition; the model
        // clamps the target so completed items always stay last (item 5).
        .draggable(item.id.uuidString)
        .dropDestination(for: String.self) { payload, _ in
            actions.handleDrop(payload, displayIndex)
        }
        .contextMenu {
            Button(String(localized: "sidebar.checklist.editItem", defaultValue: "Edit")) {
                actions.beginEdit()
            }
            if item.state != .inProgress {
                Button(String(localized: "sidebar.checklist.markInProgress", defaultValue: "Mark In Progress")) {
                    actions.markInProgress()
                }
            }
            Button(String(localized: "sidebar.checklist.removeItem", defaultValue: "Remove")) {
                actions.remove()
            }
        }
        .accessibilityIdentifier("WorkspaceTodoPaneItemRow")
    }

    private func handleRowTap() {
        switch WorkspaceTodoPaneItemRowClickPolicy.action(isEditing: isEditing, isHighlighted: isHighlighted) {
        case .select:
            actions.select()
        case .beginEdit:
            actions.beginEdit()
        case .focusEditor:
            actions.focusEditor()
        }
    }

    private func checkboxSymbolName(for state: WorkspaceChecklistItem.State) -> String {
        switch state {
        case .pending: return "square"
        case .inProgress: return "minus.square"
        case .completed: return "checkmark.square.fill"
        }
    }
}
