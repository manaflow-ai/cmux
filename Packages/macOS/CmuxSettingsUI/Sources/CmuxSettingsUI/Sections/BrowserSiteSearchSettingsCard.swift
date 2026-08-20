import CmuxSettings
import SwiftUI

/// Edits browser site-search shortcuts while preserving legacy defaults storage.
@MainActor
public struct BrowserSiteSearchSettingsCard: View {
    @State private var storage: DefaultsValueModel<String>
    @State private var activation: DefaultsValueModel<BrowserSiteSearchActivationShortcut>
    @State private var draft: [BrowserSiteSearchShortcut]

    /// Creates an editor bound to the browser catalog keys.
    public init(defaultsStore: UserDefaultsSettingsStore, catalog: SettingCatalog) {
        _storage = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.browser.siteSearchShortcutsStorage))
        _activation = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.browser.siteSearchActivationShortcut))
        _draft = State(initialValue: BrowserSiteSearchSettings.decode(defaultsStore.initialValue(for: catalog.browser.siteSearchShortcutsStorage)))
    }

    public var body: some View {
        SettingsCard {
            SettingsCardRow(configurationReview: .settingsOnly, searchAnchorID: "setting:browser:site-search", String(localized: "settings.browser.siteSearch.title", defaultValue: "Browser Site Search"), subtitle: String(localized: "settings.browser.siteSearch.subtitle", defaultValue: "Use shortcuts such as pr 1234 to search a configured site.")) {
                Picker("", selection: Binding(get: { activation.current }, set: { activation.set($0) })) {
                    ForEach(BrowserSiteSearchActivationShortcut.allCases) { Text($0.displayName).tag($0) }
                }.labelsHidden().controlSize(.small)
            }
            SettingsCardDivider()
            ForEach($draft) { $row in
                HStack(spacing: 8) {
                    TextField(String(localized: "settings.browser.siteSearch.name", defaultValue: "Name"), text: $row.name)
                        .accessibilityIdentifier("browser.siteSearch.name.\(row.id.uuidString)")
                    TextField(String(localized: "settings.browser.siteSearch.shortcut", defaultValue: "Shortcut"), text: $row.shortcut)
                        .accessibilityIdentifier("browser.siteSearch.shortcut.\(row.shortcut)")
                    TextField(String(localized: "settings.browser.siteSearch.url", defaultValue: "URL template"), text: $row.urlTemplate)
                    Toggle(String(localized: "settings.browser.siteSearch.active", defaultValue: "Active"), isOn: $row.isActive)
                        .labelsHidden()
                    Button(role: .destructive) { draft.removeAll { $0.id == row.id }; persist() } label: { Image(systemName: "minus.circle") }
                        .accessibilityIdentifier("browser.siteSearch.remove.\(row.id.uuidString)")
                }
                .onChange(of: row.name) { _, _ in persist() }
                .onChange(of: row.shortcut) { _, _ in persist() }
                .onChange(of: row.urlTemplate) { _, _ in persist() }
                .onChange(of: row.isActive) { _, _ in persist() }
                .padding(.vertical, 4)
            }
            Button { draft.append(BrowserSiteSearchShortcut(name: "", shortcut: "", urlTemplate: "https://example.com/?q=%s")); persist() } label: { Label(String(localized: "settings.browser.siteSearch.add", defaultValue: "Add shortcut"), systemImage: "plus") }
                .accessibilityIdentifier("browser.siteSearch.add")
        }
        .task { storage.startObserving(); activation.startObserving() }
    }

    private func persist() {
        storage.set(BrowserSiteSearchSettings.encode(draft))
    }
}
