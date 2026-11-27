import CmuxFoundation
import CmuxSettings
import SwiftUI

/// The **Base Keymap** picker. Choosing a preset (here or from the Command
/// Palette) previews what would change, including shortcuts macOS may take
/// first, and writes `shortcuts.bindings` only after the user confirms.
///
/// Only the chosen preset is stored. The plan is derived from the current
/// bindings on every render and again on Apply, so it never goes stale, and
/// nothing is planned until the store has delivered the first bindings.
@MainActor
struct ShortcutKeymapPresetRow: View {
    let model: ShortcutListModel
    let proposals: ShortcutKeymapProposalInbox?
    @State private var proposedPreset: ShortcutKeymapPreset?
    @State private var isApplying = false

    private var snapshot: ShortcutBindingsSnapshot {
        ShortcutBindingsSnapshot(
            bindings: model.latestBindings,
            managedActionIDs: model.managedBindingActionIDs
        )
    }

    private var activePreset: ShortcutKeymapPreset? {
        ShortcutKeymapPreset.active(
            in: snapshot,
            legacyBindings: model.legacyBindings,
            defaultShortcutResolver: model.defaultShortcutResolver
        )
    }

    /// The preview for ``proposedPreset``, or `nil` while nothing is proposed or
    /// the bindings haven't loaded yet.
    private var proposedPlan: ShortcutKeymapPlan? {
        guard let proposedPreset, model.hasLoadedBindings else { return nil }
        return plan(for: proposedPreset)
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
                        get: { proposedPreset ?? activePreset },
                        set: { preset in
                            if let preset { propose(preset) }
                        }
                    )
                ) {
                    ForEach(ShortcutKeymapPreset.allCases, id: \.self) { preset in
                        Text(preset.displayName).tag(Optional(preset))
                    }
                    if proposedPreset == nil, activePreset == nil {
                        Text(String(localized: "settings.shortcuts.baseKeymap.custom", defaultValue: "Custom"))
                            .tag(ShortcutKeymapPreset?.none)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .disabled(isApplying)
                .accessibilityIdentifier("SettingsKeyboardShortcutsBaseKeymapPicker")
            }
            if let proposedPlan {
                preview(proposedPlan)
            }
        }
        .onAppear { takeProposal() }
        .onChange(of: proposals?.preset) { _, _ in takeProposal() }
    }

    @ViewBuilder
    private func preview(_ plan: ShortcutKeymapPlan) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(plan.summaryLines.enumerated()), id: \.offset) { _, line in
                Text(line)
                    .cmuxFont(.caption)
                    .foregroundColor(.secondary)
                    .textSelection(.enabled)
            }
            if !plan.systemConflicts.isEmpty {
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
            HStack(spacing: 8) {
                Spacer()
                Button(String(localized: "common.cancel", defaultValue: "Cancel")) {
                    proposedPreset = nil
                }
                .controlSize(.small)
                .accessibilityIdentifier("SettingsKeyboardShortcutsBaseKeymapCancel")
                Button(String(localized: "settings.shortcuts.baseKeymap.apply", defaultValue: "Apply Keymap")) {
                    apply(plan.preset)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(plan.isEmpty || isApplying || !model.hasLoadedBindings)
                .accessibilityIdentifier("SettingsKeyboardShortcutsBaseKeymapApply")
            }
            .padding(.top, 4)
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 9)
        .accessibilityIdentifier("SettingsKeyboardShortcutsBaseKeymapPreview")
    }

    private func plan(for preset: ShortcutKeymapPreset) -> ShortcutKeymapPlan {
        preset.plan(
            from: snapshot,
            legacyBindings: model.legacyBindings,
            defaultShortcutResolver: model.defaultShortcutResolver
        )
    }

    private func propose(_ preset: ShortcutKeymapPreset) {
        proposedPreset = preset == activePreset ? nil : preset
    }

    private func takeProposal() {
        guard let proposals, let preset = proposals.preset else { return }
        proposals.preset = nil
        proposedPreset = preset
    }

    /// Plans again from the bindings as they are now, so edits made while the
    /// preview was open are respected.
    private func apply(_ preset: ShortcutKeymapPreset) {
        guard model.hasLoadedBindings else { return }
        let freshPlan = plan(for: preset)
        guard !freshPlan.isEmpty else {
            proposedPreset = nil
            return
        }
        isApplying = true
        Task {
            defer { isApplying = false }
            do {
                try await model.jsonStore.applyShortcutKeymap(freshPlan, bindingsID: model.catalog.shortcuts.bindings.id)
                model.onShortcutsChanged()
                proposedPreset = nil
            } catch {
                model.errorLog.record(error, keyID: model.catalog.shortcuts.bindings.id)
            }
        }
    }
}
