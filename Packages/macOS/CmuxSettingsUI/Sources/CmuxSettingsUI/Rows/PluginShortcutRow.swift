import CmuxFoundation
import CmuxSettings
import Foundation
import SwiftUI

/// A lightweight recorder row for a runtime plugin action.
@MainActor
struct PluginShortcutRow: View {
    let descriptor: PluginShortcutDescriptor
    let setShortcut: (StoredShortcut) -> Void
    let conflictName: (StoredShortcut) -> String?

    @State private var current: StoredShortcut?
    @State private var validationMessage: String?
    @State private var restorableShortcut: StoredShortcut?

    init(
        descriptor: PluginShortcutDescriptor,
        setShortcut: @escaping (StoredShortcut) -> Void,
        conflictName: @escaping (StoredShortcut) -> String?
    ) {
        self.descriptor = descriptor
        self.setShortcut = setShortcut
        self.conflictName = conflictName
        _current = State(initialValue: descriptor.shortcut)
        _validationMessage = State(initialValue: Self.conflictMessage(
            conflictingAction: descriptor.conflictDisplayName,
            shortcut: descriptor.shortcut
        ))
        _restorableShortcut = State(initialValue: nil)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(descriptor.title)
                    if let subtitle = descriptor.subtitle {
                        Text(subtitle)
                            .cmuxFont(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                ShortcutRecorderView(
                    placeholder: ShortcutDisplayFormatter().displayString(current ?? .unbound),
                    chordsEnabled: true,
                    hasPendingRejection: validationMessage != nil,
                    firstStrokeRequiresModifier: true,
                    onStroke: { stroke in
                        accept(StoredShortcut(first: stroke))
                    },
                    onChord: accept,
                    onBareKeyRejected: {
                        validationMessage = String(
                            localized: "shortcut.recorder.error.bareKeyNotAllowed",
                            defaultValue: "Shortcuts must include ⌘ ⌥ ⌃ or ⇧"
                        )
                    }
                )
                .frame(width: 160)
                Button {
                    clearOrRestore()
                } label: {
                    Image(systemName: canRestore ? "arrow.counterclockwise.circle.fill" : "xmark.circle.fill")
                        .imageScale(.medium)
                }
                .buttonStyle(.borderless)
                .disabled((current?.isUnbound ?? true) && !canRestore)
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
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            if let validationMessage {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .cmuxFont(.caption)
                        .foregroundStyle(.red)
                    Text(validationMessage)
                        .cmuxFont(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                    Button(String(localized: "shortcut.recorder.undo", defaultValue: "Undo")) {
                        self.validationMessage = nil
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
                .padding(.horizontal, 14)
                .padding(.bottom, 9)
            }
        }
        .onChange(of: descriptor) { _, descriptor in
            current = descriptor.shortcut
            if descriptor.shortcut?.isUnbound != true {
                restorableShortcut = nil
            }
            validationMessage = Self.conflictMessage(
                conflictingAction: descriptor.conflictDisplayName,
                shortcut: descriptor.shortcut
            )
        }
    }

    private func accept(_ shortcut: StoredShortcut) {
        if let conflictingAction = conflictName(shortcut) {
            validationMessage = Self.conflictMessage(
                conflictingAction: conflictingAction,
                shortcut: shortcut
            )
            return
        }
        validationMessage = nil
        setShortcut(shortcut)
    }

    private var canRestore: Bool {
        current?.isUnbound == true && restorableShortcut != nil
    }

    private func clearOrRestore() {
        validationMessage = nil
        if canRestore, let restorableShortcut {
            setShortcut(restorableShortcut)
            return
        }
        guard let current, !current.isUnbound else { return }
        restorableShortcut = current
        setShortcut(.unbound)
    }

    private static func conflictMessage(
        conflictingAction: String?,
        shortcut: StoredShortcut?
    ) -> String? {
        guard let conflictingAction, let shortcut else { return nil }
        let format = String(
            localized: "shortcut.recorder.error.conflictsWithAction",
            defaultValue: "This shortcut conflicts with %@ (%@)."
        )
        return String.localizedStringWithFormat(
            format,
            conflictingAction,
            ShortcutDisplayFormatter().displayString(shortcut)
        )
    }
}
