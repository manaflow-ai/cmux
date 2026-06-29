import CmuxFoundation
import CmuxSettings
import SwiftUI

/// **Keyboard Shortcuts** section — mirrors the legacy in-app
/// section: one `SettingsCard` containing the chord docs link,
/// the Reset Defaults action, and a per-action recorder row for
/// every `ShortcutAction` (using the new package recorder).
@MainActor
public struct KeyboardShortcutsSection: View {
    private let hostActions: SettingsHostActions
    @State private var model: ShortcutListModel

    // Build-time list-rendering selector (NOT a user-facing option). Both paths fix the
    // deactivate/reactivate scroll-jump (neither uses a LazyVStack); they differ in layout:
    //   false (default) — `ShortcutListEagerView`: full-height inline list, flows in the page
    //                     like upstream (no inner scroll). Realizes all ~166 recorders at open.
    //   true            — `ShortcutListView`: virtualized NSTableView in a bounded box (recycled
    //                     cells, fast open) but with its own inner scroll region.
    // Default is inline to match upstream's single continuous scroll. Flip to `true` to trade
    // that for fast open + low memory if the eager open-cost proves too high.
    private static let useVirtualizedList = false

    // TUNABLE (virtualized path only) — bounded viewport that keeps the table's contribution to
    // the outer-page height constant across the active-state flip AND keeps the table virtualized.
    // Tune during ./scripts/reload.sh — too short = cramped, too tall = page-dominating.
    private static let shortcutListBoxHeight: CGFloat = 520

    public init(
        jsonStore: JSONConfigStore,
        catalog: SettingCatalog,
        errorLog: SettingsErrorLog,
        hostActions: SettingsHostActions
    ) {
        self.hostActions = hostActions
        _model = State(initialValue: ShortcutListModel(jsonStore: jsonStore, catalog: catalog, errorLog: errorLog))
    }

    public var body: some View {
        Group {
            SettingsSectionHeader(String(localized: "settings.section.keyboardShortcuts", defaultValue: "Keyboard Shortcuts"), section: .keyboardShortcuts)
                .accessibilityIdentifier("SettingsKeyboardShortcutsSection")
            SettingsCard {
                chordsRow
                SettingsCardDivider()
                ModifierHoldHintsSettingsRow()
                SettingsCardDivider()
                resetDefaultsRow
                SettingsCardDivider()
                if Self.useVirtualizedList {
                    ShortcutListView(model: model, heightRevision: model.heightRevision)
                        .frame(height: Self.shortcutListBoxHeight)
                } else {
                    ShortcutListEagerView(model: model)
                }
            }
            .settingsSearchAnchors(["setting:keyboardShortcuts:shortcuts"])
            Text(String(localized: "settings.shortcuts.recordHint", defaultValue: "Click a shortcut value to record. Use X to unbind; it changes to restore after a clear."))
                .cmuxFont(.caption)
                .foregroundColor(.secondary)
                .padding(.leading, 2)
                .accessibilityIdentifier("ShortcutRecordingHint")
        }
        .task { model.startObserving() }
    }

    @ViewBuilder
    private var chordsRow: some View {
        SettingsCardRow(
            configurationReview: .action,
            searchAnchorID: "setting:keyboardShortcuts:shortcut-chords",
            String(localized: "settings.shortcuts.chords", defaultValue: "Shortcut Chords"),
            subtitle: String(localized: "settings.shortcuts.chords.subtitle", defaultValue: "Add tmux-style multi-step shortcuts in cmux.json, for example [\"ctrl+b\", \"c\"].")
        ) {
            HStack(spacing: 8) {
                Link(
                    String(localized: "settings.shortcuts.chords.docsButton", defaultValue: "Chord docs"),
                    destination: URL(string: "https://cmux.com/docs/keyboard-shortcuts#shortcut-chords")!
                )
                .cmuxFont(.caption)
                .accessibilityIdentifier("SettingsKeyboardShortcutsChordDocsLink")

                Button(String(localized: "settings.app.settingsFile.openButton", defaultValue: "Open cmux.json")) {
                    hostActions.openConfigInExternalEditor()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityIdentifier("SettingsKeyboardShortcutsOpenSettingsFileButton")
            }
        }
    }

    @ViewBuilder
    private var resetDefaultsRow: some View {
        SettingsCardRow(
            configurationReview: .settingsOnly,
            searchAnchorID: "setting:keyboardShortcuts:reset-defaults",
            String(localized: "settings.shortcuts.resetDefaults", defaultValue: "Reset Default Shortcuts"),
            subtitle: String(localized: "settings.shortcuts.resetDefaults.subtitle", defaultValue: "Restore built-in shortcut values for shortcuts managed in app settings.")
        ) {
            Button {
                Task { await model.resetAll() }
            } label: {
                Label(
                    String(localized: "settings.shortcuts.resetDefaults.button", defaultValue: "Reset Defaults"),
                    systemImage: "arrow.counterclockwise"
                )
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityIdentifier("SettingsKeyboardShortcutsResetDefaultsButton")
        }
    }
}
