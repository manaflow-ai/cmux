import CmuxSettings
import SwiftUI

/// **Reset** section.
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
        VStack(alignment: .leading, spacing: 18) {
            SettingsSectionHeader("Reset")
            SettingsCard {
                SettingsCardRow(configurationReview: .action, "Reset All Settings",
                    subtitle: "Reverts every setting in the catalog to its declared default. UserDefaults overrides are deleted; entries in cmux.json are removed. Keyboard shortcut bindings are not reset by this action.") {
                    Button(role: .destructive) {
                        showingConfirmation = true
                    } label: {
                        Label("Reset All Settings", systemImage: "arrow.counterclockwise")
                    }
                    .controlSize(.small)
                }
            }
        }
        .confirmationDialog(
            "Reset all settings?",
            isPresented: $showingConfirmation
        ) {
            Button("Reset", role: .destructive) { Task { await resetAll() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This cannot be undone.")
        }
    }

    private func resetAll() async {
        await defaultsStore.resetAll(catalog.all)
        for key in catalog.all {
            await key.resetInJSON(jsonStore)
        }
    }
}
