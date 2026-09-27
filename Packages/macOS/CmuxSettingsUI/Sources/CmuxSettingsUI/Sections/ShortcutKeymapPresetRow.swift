import CmuxFoundation
import CmuxSettings
import SwiftUI

/// The **Base Keymap** picker: switches `shortcuts.bindings` to a preset and
/// lists what changed, including shortcuts macOS may take first.
@MainActor
struct ShortcutKeymapPresetRow: View {
    let model: ShortcutListModel
    @State private var lastPlan: ShortcutKeymapPlan?
    @State private var isApplying = false

    private var snapshot: ShortcutBindingsSnapshot {
        ShortcutBindingsSnapshot(
            bindings: model.latestBindings,
            managedActionIDs: model.managedBindingActionIDs
        )
    }

    private var activePreset: ShortcutKeymapPreset? {
        ShortcutKeymapPreset.active(in: snapshot, defaultShortcutResolver: model.defaultShortcutResolver)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsCardRow(
                configurationReview: .json("shortcuts.bindings"),
                searchAnchorID: "setting:keyboardShortcuts:base-keymap",
                String(localized: "settings.shortcuts.baseKeymap", defaultValue: "Base Keymap"),
                subtitle: String(
                    localized: "settings.shortcuts.baseKeymap.subtitle",
                    defaultValue: "Start from another terminal's shortcuts. Only the differences are written to cmux.json; choose cmux to remove them."
                ),
                controlWidth: 220
            ) {
                Picker(
                    String(localized: "settings.shortcuts.baseKeymap", defaultValue: "Base Keymap"),
                    selection: Binding(
                        get: { activePreset },
                        set: { preset in
                            if let preset { apply(preset) }
                        }
                    )
                ) {
                    ForEach(ShortcutKeymapPreset.allCases, id: \.self) { preset in
                        Text(preset.displayName).tag(Optional(preset))
                    }
                    if activePreset == nil {
                        Text(String(localized: "settings.shortcuts.baseKeymap.custom", defaultValue: "Custom"))
                            .tag(ShortcutKeymapPreset?.none)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .disabled(isApplying)
                .accessibilityIdentifier("SettingsKeyboardShortcutsBaseKeymapPicker")
            }
            if let lastPlan {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(ShortcutKeymapPlanText.lines(for: lastPlan).enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .cmuxFont(.caption)
                            .foregroundColor(.secondary)
                            .textSelection(.enabled)
                    }
                    if !lastPlan.systemConflicts.isEmpty {
                        Label(
                            String(
                                localized: "settings.shortcuts.baseKeymap.conflictHint",
                                defaultValue: "Change or turn off the macOS shortcut in System Settings > Keyboard > Keyboard Shortcuts."
                            ),
                            systemImage: "exclamationmark.triangle"
                        )
                        .cmuxFont(.caption)
                        .foregroundColor(.orange)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 9)
                .accessibilityIdentifier("SettingsKeyboardShortcutsBaseKeymapSummary")
            }
        }
    }

    private func apply(_ preset: ShortcutKeymapPreset) {
        let plan = preset.plan(from: snapshot, defaultShortcutResolver: model.defaultShortcutResolver)
        lastPlan = plan
        guard !plan.isEmpty else { return }
        isApplying = true
        Task {
            defer { isApplying = false }
            do {
                try await model.jsonStore.applyShortcutKeymap(plan, bindingsID: model.catalog.shortcuts.bindings.id)
                model.onShortcutsChanged()
            } catch {
                model.errorLog.record(error, keyID: model.catalog.shortcuts.bindings.id)
            }
        }
    }
}
