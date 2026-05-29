import CmuxSettings
import SwiftUI

/// **Reset** section — mirrors the legacy in-app section: a single
/// centered "Reset All Settings" button wrapped in a `SettingsCard`.
/// Clearing both stores happens via the confirmation dialog.
@MainActor
public struct ResetSection: View {
    private let defaultsStore: UserDefaultsSettingsStore
    private let jsonStore: JSONConfigStore
    private let catalog: SettingCatalog

    @State private var showingConfirmation = false

    public init(defaultsStore: UserDefaultsSettingsStore, jsonStore: JSONConfigStore, catalog: SettingCatalog) {
        self.defaultsStore = defaultsStore
        self.jsonStore = jsonStore
        self.catalog = catalog
    }

    public var body: some View {
        Group {
            SettingsSectionHeader(String(localized: "settings.section.reset", defaultValue: "Reset"))
            SettingsCard {
                HStack {
                    Spacer(minLength: 0)
                    Button(String(localized: "settings.reset.resetAll", defaultValue: "Reset All Settings")) {
                        showingConfirmation = true
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
        }
        .confirmationDialog(
            String(localized: "settings.reset.dialog.title", defaultValue: "Reset all settings?"),
            isPresented: $showingConfirmation,
            titleVisibility: .visible
        ) {
            Button(String(localized: "settings.reset.dialog.confirm", defaultValue: "Reset"), role: .destructive) {
                Task { await resetAll() }
            }
            Button(String(localized: "settings.reset.dialog.cancel", defaultValue: "Cancel"), role: .cancel) {}
        } message: {
            Text(String(localized: "settings.reset.dialog.message", defaultValue: "This cannot be undone."))
        }
    }

    private func resetAll() async {
        await defaultsStore.resetAll(catalog.all)
        for key in catalog.all {
            await key.resetInJSON(jsonStore)
        }
    }
}
