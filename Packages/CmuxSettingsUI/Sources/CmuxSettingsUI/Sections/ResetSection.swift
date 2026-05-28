import CmuxSettings
import SwiftUI

/// SwiftUI view for the **Reset** section.
///
/// Provides a "reset all settings to defaults" action that walks
/// ``SettingCatalog/all`` and calls ``UserDefaultsSettingsStore/reset(_:)``
/// or ``JSONConfigStore/reset(_:)`` on each entry as appropriate. A
/// confirmation dialog gates the destructive action.
public struct ResetSection: View {
    private let defaultsStore: UserDefaultsSettingsStore
    private let jsonStore: JSONConfigStore
    private let catalog: SettingCatalog

    @State private var showingConfirmation = false

    public init(
        defaultsStore: UserDefaultsSettingsStore,
        jsonStore: JSONConfigStore,
        catalog: SettingCatalog
    ) {
        self.defaultsStore = defaultsStore
        self.jsonStore = jsonStore
        self.catalog = catalog
    }

    public var body: some View {
        Form {
            Section {
                Button(role: .destructive) {
                    showingConfirmation = true
                } label: {
                    Label("Reset all settings to defaults", systemImage: "arrow.counterclockwise")
                }
            } footer: {
                Text("Reverts every setting in the catalog to its declared default. UserDefaults overrides are deleted; entries in cmux.json are removed. Keyboard shortcut bindings are not reset by this action.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .confirmationDialog(
            "Reset all settings?",
            isPresented: $showingConfirmation
        ) {
            Button("Reset", role: .destructive) {
                Task {
                    await resetAll()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This cannot be undone.")
        }
    }

    private func resetAll() async {
        await defaultsStore.resetAll(catalog.all)
        for key in catalog.all {
            await resetJSONKeyIfApplicable(key)
        }
    }

    private func resetJSONKeyIfApplicable(_ key: AnySettingKey) async {
        // Best-effort: dispatch a reset through the type-erased key.
        // Failures (e.g. on a UserDefaults-backed key) are intentionally
        // swallowed because the key's `reset` is a no-op in that case.
        await key.resetInJSON(jsonStore)
    }
}
