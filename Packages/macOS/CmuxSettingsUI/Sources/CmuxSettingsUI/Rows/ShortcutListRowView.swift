// Sources/CmuxSettingsUI/Rows/ShortcutListRowView.swift
import AppKit
import CmuxFoundation
import CmuxSettings
import SwiftUI

/// A single shortcut-recorder row for the Keyboard Shortcuts settings section.
///
/// Extracted from ``KeyboardShortcutsSection/actionRow(_:)`` verbatim so it can
/// be hosted inside recycled `NSTableView` cells (Task 5). The ``ShortcutListModel``
/// owns all state; this view is purely display + callback wiring.
///
/// Pass `isLast: true` for the final row so the trailing hairline is suppressed.
/// The hairline replaces `SettingsCardDivider` from the LazyVStack layout, matching
/// it visually while working with zero intercell spacing in the NSTableView host.
@MainActor
struct ShortcutListRowView: View {
    let model: ShortcutListModel
    let action: ShortcutAction
    let isLast: Bool

    init(model: ShortcutListModel, action: ShortcutAction, isLast: Bool) {
        self.model = model
        self.action = action
        self.isLast = isLast
    }

    var body: some View {
        let effective = model.effective(for: action)
        let isUnbound = effective?.isUnbound ?? true
        let canRestore = model.canRestore(for: action)
        let bareKeyRejected = model.bareKeyRejections.contains(action.rawValue)
        let numberedDigitRejected = model.numberedDigitRejections.contains(action.rawValue)
        let validationMessage = model.validationMessage(for: action)
        let subtitle = model.scopeCaption(for: action)

        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: subtitle == nil ? .center : .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(action.displayName)
                        if let subtitle {
                            Text(subtitle)
                                .cmuxFont(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Spacer()

                    ShortcutRecorderView(
                        placeholder: model.formatPlaceholder(
                            effective: effective,
                            numbered: action.usesNumberedDigitMatching
                        ),
                        chordsEnabled: model.chordModeActions.contains(action.rawValue),
                        hasPendingRejection: bareKeyRejected || numberedDigitRejected,
                        firstStrokeRequiresModifier: !action.allowsBareFirstStroke,
                        onStroke: { stroke in Task { await model.assign(stroke: stroke, to: action) } },
                        onChord: { chord in Task { await model.assignChord(chord, to: action) } },
                        onBareKeyRejected: { model.markBareKeyRejected(action) }
                    )
                    .frame(width: 160)

                    Button {
                        model.clearOrRestore(for: action)
                    } label: {
                        Image(systemName: canRestore ? "arrow.counterclockwise.circle.fill" : "xmark.circle.fill")
                            .imageScale(.medium)
                    }
                    .buttonStyle(.borderless)
                    .disabled(isUnbound && !canRestore)
                    .help(
                        canRestore
                            ? String(localized: "shortcut.recorder.restore.help", defaultValue: "Restore previous shortcut")
                            : String(localized: "shortcut.recorder.clear.help", defaultValue: "Unbind shortcut")
                    )
                    .accessibilityLabel(
                        canRestore
                            ? String(localized: "shortcut.recorder.restore", defaultValue: "Restore")
                            : String(localized: "shortcut.recorder.clear", defaultValue: "Unbind")
                    )
                    .accessibilityIdentifier("ShortcutRecorderClearRestoreButton")
                }

                if let validationMessage {
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
                            model.clearRejections(for: action)
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

            if !isLast {
                Rectangle()
                    .fill(Color(nsColor: NSColor.separatorColor).opacity(0.5))
                    .frame(height: 1)
            }
        }
    }
}
