import CmuxCommandPalette
import CmuxCommandPaletteUI
import SwiftUI

/// Styling for the command palette's editor field, selecting between the
/// single-line rename field and the multiline workspace-description editor.
///
/// Lifted out of `ContentView` so the palette's input view bodies are
/// explicit-typed `View` structs (both a line-count drain and a type-check
/// timeout mitigation for `ContentView.body`).
enum CommandPaletteEditorFieldStyle {
    case singleLine(
        accessibilityIdentifier: String,
        focus: FocusState<Bool>.Binding,
        onDeleteBackward: ((EventModifiers) -> BackportKeyPressResult)?
    )
    case multiline(
        accessibilityIdentifier: String,
        accessibilityLabel: String,
        focus: Binding<Bool>,
        measuredHeight: Binding<CGFloat>,
        maxHeight: CGFloat
    )
}

/// The shared editor field used by the rename and workspace-description input
/// modes of the command palette.
struct CommandPaletteEditorField: View {
    let style: CommandPaletteEditorFieldStyle
    let placeholder: String
    @Binding var text: String
    let onSubmit: (String) -> Void
    let onEscape: () -> Void
    var onInteraction: (() -> Void)?

    init(
        style: CommandPaletteEditorFieldStyle,
        placeholder: String,
        text: Binding<String>,
        onSubmit: @escaping (String) -> Void,
        onEscape: @escaping () -> Void,
        onInteraction: (() -> Void)? = nil
    ) {
        self.style = style
        self.placeholder = placeholder
        self._text = text
        self.onSubmit = onSubmit
        self.onEscape = onEscape
        self.onInteraction = onInteraction
    }

    @ViewBuilder
    var body: some View {
        switch style {
        case .singleLine(let accessibilityIdentifier, let focus, let onDeleteBackward):
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 13, weight: .regular))
                .tint(Color(nsColor: sidebarActiveForegroundNSColor(opacity: 1.0)))
                .focused(focus)
                .accessibilityIdentifier(accessibilityIdentifier)
                .backport.onKeyPress(.delete) { modifiers in
                    onDeleteBackward?(modifiers) ?? .ignored
                }
                .onSubmit {
                    onSubmit(text)
                }
                .onTapGesture {
                    onInteraction?()
                }
        case .multiline(let accessibilityIdentifier, let accessibilityLabel, let focus, let measuredHeight, let maxHeight):
            CommandPaletteMultilineTextEditorRepresentable(
                placeholder: placeholder,
                accessibilityLabel: accessibilityLabel,
                accessibilityIdentifier: accessibilityIdentifier,
                text: $text,
                isFocused: focus,
                measuredHeight: measuredHeight,
                maxHeight: maxHeight,
                onSubmit: onSubmit,
                onEscape: onEscape
            )
            .frame(height: measuredHeight.wrappedValue)
        }
    }
}

/// The rename-input mode of the command palette (workspace or tab rename).
struct CommandPaletteRenameInputView: View {
    let target: CommandPaletteRenameTarget
    @Bindable var presentation: CommandPalettePresentationModel
    let renameFocus: FocusState<Bool>.Binding
    let onDeleteBackward: (EventModifiers) -> BackportKeyPressResult
    let onContinueRename: (CommandPaletteRenameTarget) -> Void
    let onDismiss: () -> Void
    let onInteraction: () -> Void
    let onAppearResetFocus: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            CommandPaletteEditorField(
                style: .singleLine(
                    accessibilityIdentifier: "CommandPaletteRenameField",
                    focus: renameFocus,
                    onDeleteBackward: onDeleteBackward
                ),
                placeholder: target.placeholder,
                text: $presentation.renameDraft,
                onSubmit: { _ in onContinueRename(target) },
                onEscape: onDismiss,
                onInteraction: onInteraction
            )
            .padding(.horizontal, 9)
            .padding(.vertical, 7)

            Divider()

            Text(Self.renameInputHintText(target: target))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 9)
                .padding(.vertical, 6)

            Button(action: {
                onContinueRename(target)
            }) {
                EmptyView()
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.defaultAction)
            .frame(width: 0, height: 0)
            .opacity(0)
            .accessibilityHidden(true)
        }
        .onAppear {
            onAppearResetFocus()
        }
    }

    static func renameInputHintText(target: CommandPaletteRenameTarget) -> String {
        switch target.kind {
        case .workspace:
            return String(localized: "commandPalette.rename.workspaceInputHint", defaultValue: "Enter a workspace name. Press Enter to rename, Escape to cancel.")
        case .tab:
            return String(localized: "commandPalette.rename.tabInputHint", defaultValue: "Enter a tab name. Press Enter to rename, Escape to cancel.")
        }
    }
}

/// The rename-confirmation mode of the command palette.
struct CommandPaletteRenameConfirmView: View {
    let target: CommandPaletteRenameTarget
    let proposedName: String
    let onApplyRename: (CommandPaletteRenameTarget, String) -> Void

    var body: some View {
        let trimmedName = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
        let nextName = trimmedName.isEmpty ? String(localized: "commandPalette.rename.clearCustomName", defaultValue: "(clear custom name)") : trimmedName

        return VStack(spacing: 0) {
            Text(nextName)
                .font(.system(size: 13, weight: .regular))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 9)
                .padding(.vertical, 7)

            Divider()

            Text(Self.renameConfirmHintText(target: target))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 9)
                .padding(.vertical, 6)

            Button(action: {
                onApplyRename(target, proposedName)
            }) {
                EmptyView()
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.defaultAction)
            .frame(width: 0, height: 0)
            .opacity(0)
            .accessibilityHidden(true)
        }
    }

    static func renameConfirmHintText(target: CommandPaletteRenameTarget) -> String {
        switch target.kind {
        case .workspace:
            return String(localized: "commandPalette.rename.workspaceConfirmHint", defaultValue: "Press Enter to apply this workspace name, or Escape to cancel.")
        case .tab:
            return String(localized: "commandPalette.rename.tabConfirmHint", defaultValue: "Press Enter to apply this tab name, or Escape to cancel.")
        }
    }
}

/// The workspace-description editing mode of the command palette.
struct CommandPaletteWorkspaceDescriptionInputView: View {
    let target: CommandPaletteWorkspaceDescriptionTarget
    let maxEditorHeight: CGFloat
    @Bindable var presentation: CommandPalettePresentationModel
    @Binding var shouldFocusEditor: Bool
    let observedWindow: NSWindow?
    let onApplyWorkspaceDescription: (CommandPaletteWorkspaceDescriptionTarget, String) -> Void
    let onDismiss: () -> Void
    let onAppearResetFocus: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            CommandPaletteEditorField(
                style: .multiline(
                    accessibilityIdentifier: "CommandPaletteWorkspaceDescriptionEditor",
                    accessibilityLabel: String(
                        localized: "command.editWorkspaceDescription.title",
                        defaultValue: "Edit Workspace Description…"
                    ),
                    focus: $shouldFocusEditor,
                    measuredHeight: $presentation.workspaceDescriptionHeight,
                    maxHeight: maxEditorHeight
                ),
                placeholder: target.placeholder,
                text: $presentation.workspaceDescriptionDraft,
                onSubmit: { proposedDescription in
                    onApplyWorkspaceDescription(target, proposedDescription)
                },
                onEscape: onDismiss
            )
            .padding(.horizontal, 9)
            .padding(.vertical, 7)

            Divider()

            Text(target.inputHint)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
        }
        .onAppear {
#if DEBUG
            cmuxDebugLog(
                "palette.wsDescription.view.appear workspace=\(target.workspaceId.uuidString.prefix(8)) " +
                "draftLen=\((presentation.workspaceDescriptionDraft as NSString).length) " +
                "height=\(String(format: "%.1f", presentation.workspaceDescriptionHeight)) " +
                "focusFlag=\(shouldFocusEditor ? 1 : 0)"
            )
#endif
            onAppearResetFocus()
        }
        .onChange(of: shouldFocusEditor) { _, newValue in
#if DEBUG
            cmuxDebugLog(
                "palette.wsDescription.focus.binding new=\(newValue ? 1 : 0) " +
                "mode=\(presentation.mode.debugModeLabel) " +
                "window={\((observedWindow ?? NSApp.keyWindow ?? NSApp.mainWindow).commandPaletteWindowDebugSummary)} " +
                "fr=\(((observedWindow ?? NSApp.keyWindow ?? NSApp.mainWindow)?.firstResponder).commandPaletteResponderDebugSummary)"
            )
#endif
        }
    }
}
