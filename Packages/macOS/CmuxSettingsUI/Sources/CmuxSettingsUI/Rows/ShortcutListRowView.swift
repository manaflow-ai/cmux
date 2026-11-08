// Sources/CmuxSettingsUI/Rows/ShortcutListRowView.swift
import AppKit
import CmuxFoundation
import CmuxSettings
import SwiftUI

/// A single shortcut-recorder row for the Keyboard Shortcuts settings section.
///
/// Receives an immutable snapshot plus action closures so row rendering does not
/// observe the whole ``ShortcutListModel``.
///
/// Pass `isLast: true` for the final row so the trailing hairline is suppressed.
/// The hairline replaces `SettingsCardDivider` from the LazyVStack layout, matching
/// it visually while working with zero intercell spacing in the NSTableView host.
struct ShortcutListRowView: View, Equatable {
    let snapshot: ShortcutListRowSnapshot
    let actions: ShortcutListRowActions

    init(snapshot: ShortcutListRowSnapshot, actions: ShortcutListRowActions) {
        self.snapshot = snapshot
        self.actions = actions
    }

    nonisolated static func == (lhs: ShortcutListRowView, rhs: ShortcutListRowView) -> Bool {
        lhs.snapshot == rhs.snapshot
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: snapshot.subtitle == nil ? .center : .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(snapshot.title)
                        if let subtitle = snapshot.subtitle {
                            Text(subtitle)
                                .cmuxFont(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Spacer()

                    ShortcutRecorderView(
                        placeholder: snapshot.placeholder,
                        chordsEnabled: snapshot.chordsEnabled,
                        hasPendingRejection: snapshot.hasPendingRejection,
                        firstStrokeRequiresModifier: snapshot.firstStrokeRequiresModifier,
                        onStroke: actions.onStroke,
                        onChord: actions.onChord,
                        onBareKeyRejected: actions.onBareKeyRejected
                    )
                    .frame(width: 160)
                    .accessibilityIdentifier(snapshot.recorderAccessibilityIdentifier)

                    Button {
                        actions.onClearOrRestore()
                    } label: {
                        Image(systemName: snapshot.canRestore ? "arrow.counterclockwise.circle.fill" : "xmark.circle.fill")
                            .imageScale(.medium)
                    }
                    .buttonStyle(.borderless)
                    .disabled(snapshot.isUnbound && !snapshot.canRestore)
                    .help(
                        snapshot.canRestore
                            ? String(localized: "shortcut.recorder.restore.help", defaultValue: "Restore previous shortcut")
                            : String(localized: "shortcut.recorder.clear.help", defaultValue: "Unbind shortcut")
                    )
                    .accessibilityLabel(
                        snapshot.canRestore
                            ? String(localized: "shortcut.recorder.restore", defaultValue: "Restore")
                            : String(localized: "shortcut.recorder.clear", defaultValue: "Unbind")
                    )
                    .accessibilityIdentifier("ShortcutRecorderClearRestoreButton")
                }

                if let validationMessage = snapshot.validationMessage {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .cmuxFont(.caption)
                            .foregroundStyle(.red)

                        Text(validationMessage)
                            .cmuxFont(.caption)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)

                        // Legacy `KeyboardShortcutRecorder` always renders an
                        // Undo button when `onUndoButtonPressed` is set, which
                        // `ShortcutRecorderSettingsControl` wires up for every
                        // rejected attempt (both bare-key and conflict). Match
                        // that so users can dismiss the conflict banner without
                        // having to record a different shortcut.
                        Button(String(localized: "shortcut.recorder.undo", defaultValue: "Undo")) {
                            actions.onClearRejections()
                        }
                        .buttonStyle(.link)
                        .cmuxFont(.caption)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.red.opacity(0.12))
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.red.opacity(0.35), lineWidth: 1)
                    }
                    .accessibilityIdentifier("ShortcutRecorderValidationMessage")
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)

            if !snapshot.isLast {
                Rectangle()
                    .fill(Color(nsColor: NSColor.separatorColor).opacity(0.5))
                    .frame(height: 1)
            }
        }
    }
}
