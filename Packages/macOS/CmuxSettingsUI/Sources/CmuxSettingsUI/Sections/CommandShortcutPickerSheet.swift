import CmuxFoundation
import CmuxSettings
import SwiftUI

/// The "Add Shortcut" sheet for the **Custom Commands** card.
///
/// Two-phase flow matching the feature request: first a fuzzy-searchable command
/// picker (ranked by the host with the Command Palette's own engine), then a
/// single-stroke recorder for the chosen command. Recording a keystroke already
/// used by a built-in action or another command is blocked with a banner; the
/// user can record a different keystroke or go back to pick another command.
@MainActor
struct CommandShortcutPickerSheet: View {
    /// Ranks the catalog for a query using the host's Command Palette engine.
    let search: (String) -> [CommandShortcutCatalogEntry]
    /// Commands that already have a binding (shown with a checkmark so the user
    /// can tell which they have customized; re-picking one rebinds it).
    let alreadyBoundCommandIds: Set<String>
    /// Conflict probe: given a proposed stroke (and the command id to exclude
    /// when rebinding), returns the colliding binding's label, or `nil`.
    let conflictLabel: (StoredShortcut, String?) -> String?
    /// Commits a binding and closes the sheet.
    let onAssign: (String, StoredShortcut) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var query: String = ""
    @State private var results: [CommandShortcutCatalogEntry] = []
    @State private var pendingCommand: CommandShortcutCatalogEntry?
    @State private var conflictMessage: String?
    @State private var bareKeyRejected = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if let pendingCommand {
                recordView(for: pendingCommand)
            } else {
                pickerView
            }
        }
        .frame(width: 460, height: 420)
        .onAppear { results = search("") }
    }

    // MARK: - Header

    @ViewBuilder
    private var header: some View {
        HStack {
            if pendingCommand != nil {
                Button {
                    resetToPicker()
                } label: {
                    Label(
                        String(localized: "common.back", defaultValue: "Back"),
                        systemImage: "chevron.left"
                    )
                    .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.borderless)
                .accessibilityIdentifier("CommandShortcutPickerBackButton")
            }
            Text(
                pendingCommand == nil
                    ? String(localized: "settings.customCommands.picker.title", defaultValue: "Add Command Shortcut")
                    : String(localized: "settings.customCommands.record.title", defaultValue: "Record Shortcut")
            )
            .cmuxFont(.headline)
            Spacer()
            Button(String(localized: "common.cancel", defaultValue: "Cancel")) {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
            .accessibilityIdentifier("CommandShortcutPickerCancelButton")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Picker phase

    @ViewBuilder
    private var pickerView: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField(
                    String(localized: "settings.customCommands.picker.searchPlaceholder", defaultValue: "Search commands…"),
                    text: $query
                )
                .textFieldStyle(.plain)
                .accessibilityIdentifier("CommandShortcutPickerSearchField")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background {
                RoundedRectangle(cornerRadius: 7).fill(Color.secondary.opacity(0.12))
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)

            if results.isEmpty {
                Spacer()
                Text(String(localized: "settings.customCommands.picker.noResults", defaultValue: "No matching commands."))
                    .cmuxFont(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(results) { entry in
                            pickerRow(entry)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
                }
            }
        }
        .onChange(of: query) { _, newValue in
            results = search(newValue)
        }
    }

    @ViewBuilder
    private func pickerRow(_ entry: CommandShortcutCatalogEntry) -> some View {
        Button {
            pendingCommand = entry
            conflictMessage = nil
            bareKeyRejected = false
        } label: {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.title)
                    Text(entry.subtitle)
                        .cmuxFont(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if alreadyBoundCommandIds.contains(entry.commandId) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .help(String(localized: "settings.customCommands.picker.alreadyBound", defaultValue: "Already has a shortcut"))
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("CommandShortcutPickerRow")
    }

    // MARK: - Record phase

    @ViewBuilder
    private func recordView(for entry: CommandShortcutCatalogEntry) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title)
                    .cmuxFont(.headline)
                Text(entry.subtitle)
                    .cmuxFont(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                Text(String(localized: "settings.customCommands.record.prompt", defaultValue: "Shortcut"))
                Spacer()
                ShortcutRecorderView(
                    hasPendingRejection: bareKeyRejected,
                    firstStrokeRequiresModifier: true,
                    onStroke: { stroke in handleStroke(stroke, for: entry) },
                    onBareKeyRejected: {
                        bareKeyRejected = true
                        conflictMessage = nil
                    }
                )
                .frame(width: 180)
            }

            if let message = validationMessage {
                ShortcutValidationBanner(message: message) {
                    conflictMessage = nil
                    bareKeyRejected = false
                }
            }

            Text(String(
                localized: "settings.customCommands.record.help",
                defaultValue: "Press a single keystroke that includes ⌘, ⌥, or ⌃."
            ))
            .cmuxFont(.caption)
            .foregroundStyle(.secondary)

            Spacer()
        }
        .padding(16)
    }

    private var validationMessage: String? {
        if bareKeyRejected {
            return String(
                localized: "shortcut.recorder.error.commandRequiresPrimaryModifier",
                defaultValue: "Command shortcuts must include ⌘, ⌥, or ⌃."
            )
        }
        if let conflictMessage {
            let format = String(
                localized: "shortcut.recorder.error.conflictsWithBinding",
                defaultValue: "This shortcut conflicts with %@."
            )
            return String.localizedStringWithFormat(format, conflictMessage)
        }
        return nil
    }

    private func handleStroke(_ stroke: ShortcutStroke, for entry: CommandShortcutCatalogEntry) {
        // The recorder requires some modifier, but a command shortcut needs a
        // primary one (⌘/⌥/⌃) — a shift-only printable key would steal typing.
        guard stroke.command || stroke.option || stroke.control else {
            bareKeyRejected = true
            conflictMessage = nil
            return
        }
        let proposed = StoredShortcut(first: stroke)
        if let conflict = conflictLabel(proposed, entry.commandId) {
            conflictMessage = conflict
            bareKeyRejected = false
            return
        }
        conflictMessage = nil
        bareKeyRejected = false
        onAssign(entry.commandId, proposed)
        dismiss()
    }

    private func resetToPicker() {
        pendingCommand = nil
        conflictMessage = nil
        bareKeyRejected = false
    }
}
