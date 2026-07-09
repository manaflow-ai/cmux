import AppKit
import CmuxSettings
import SwiftUI
import UniformTypeIdentifiers

/// **Extensions** card in the Browser section.
///
/// Shows only extensions the user has added: Safari web extensions imported
/// from apps installed on this Mac (the Import menu lists what the host
/// discovers) and unpacked WebExtension directories. Each row has an enable
/// toggle and a Remove button. State persists under `browser.webExtensions`;
/// the host observes that key and loads/unloads extensions live.
@MainActor
struct BrowserWebExtensionsCard: View {
    let model: JSONValueModel<[BrowserWebExtensionEntry]>
    let hostActions: SettingsHostActions

    @State private var discovered: [SettingsDiscoveredBrowserExtension] = []

    var body: some View {
        SettingsCard {
            headerRow
            if supported {
                ForEach(model.current) { entry in
                    SettingsCardDivider()
                    entryRow(entry)
                }
                if model.current.isEmpty {
                    SettingsCardDivider()
                    emptyRow
                }
            }
        }
        .task {
            model.startObserving()
            discovered = await hostActions.discoverBrowserWebExtensions()
        }
    }

    private var supported: Bool {
        hostActions.browserWebExtensionsSupported()
    }

    /// Discovered Safari extensions not yet added, offered by the Import menu.
    private var importableExtensions: [SettingsDiscoveredBrowserExtension] {
        let addedIDs = Set(model.current.map(\.id))
        return discovered.filter { !addedIDs.contains($0.id) }
    }

    private var headerRow: some View {
        SettingsCardRow(
            configurationReview: .json("browser.webExtensions"),
            searchAnchorID: "setting:browser:web-extensions",
            String(localized: "settings.browser.webExtensions", defaultValue: "Extensions"),
            subtitle: supported
                ? String(
                    localized: "settings.browser.webExtensions.subtitle",
                    defaultValue: "Safari web extensions from installed apps, or unpacked extension folders."
                )
                : String(
                    localized: "settings.browser.webExtensions.unsupported",
                    defaultValue: "Web extensions require macOS 15.4 or later."
                )
        ) {
            HStack(spacing: 8) {
                importMenu
                Button(String(
                    localized: "settings.browser.webExtensions.addUnpacked",
                    defaultValue: "Add Unpacked…"
                )) {
                    addUnpackedExtension()
                }
                .controlSize(.small)
                .disabled(!supported)
                .accessibilityIdentifier("BrowserWebExtensionsAddUnpackedButton")
            }
        }
    }

    private var importMenu: some View {
        Menu(String(
            localized: "settings.browser.webExtensions.importSafari",
            defaultValue: "Import Safari Extension"
        )) {
            if importableExtensions.isEmpty {
                Button(String(
                    localized: "settings.browser.webExtensions.importSafari.none",
                    defaultValue: "No Importable Extensions Found"
                )) {}
                    .disabled(true)
            }
            ForEach(importableExtensions) { candidate in
                Button(candidate.displayName ?? candidate.id) {
                    importSafariExtension(candidate)
                }
            }
        }
        .controlSize(.small)
        .fixedSize()
        .disabled(!supported)
        .accessibilityIdentifier("BrowserWebExtensionsImportMenu")
    }

    private var emptyRow: some View {
        SettingsCardRow(
            configurationReview: .settingsOnly,
            String(
                localized: "settings.browser.webExtensions.noneAdded",
                defaultValue: "No extensions added"
            ),
            subtitle: String(
                localized: "settings.browser.webExtensions.noneAdded.subtitle",
                defaultValue: "Import a Safari web extension from an installed app, or add an unpacked extension folder."
            )
        ) {
            EmptyView()
        }
    }

    private func entryRow(_ entry: BrowserWebExtensionEntry) -> some View {
        SettingsCardRow(
            configurationReview: .json("browser.webExtensions"),
            entry.displayName ?? (entry.path as NSString).lastPathComponent,
            subtitle: entry.kind == .safariAppExtension ? entry.id : entry.path
        ) {
            HStack(spacing: 8) {
                Toggle("", isOn: Binding(
                    get: { isEnabled(entry.id) },
                    set: { setEnabled($0, id: entry.id) }
                ))
                .labelsHidden()
                .controlSize(.small)
                .accessibilityIdentifier("BrowserWebExtensionToggle-\(entry.id)")
                Button(String(
                    localized: "settings.browser.webExtensions.remove",
                    defaultValue: "Remove"
                )) {
                    remove(id: entry.id)
                }
                .controlSize(.small)
            }
        }
    }

    private func isEnabled(_ id: String) -> Bool {
        model.current.first { $0.id == id }?.enabled ?? false
    }

    private func setEnabled(_ enabled: Bool, id: String) {
        var entries = model.current
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].enabled = enabled
        model.set(entries)
    }

    private func add(_ entry: BrowserWebExtensionEntry) {
        var entries = model.current
        guard !entries.contains(where: { $0.id == entry.id }) else { return }
        entries.append(entry)
        model.set(entries)
    }

    private func remove(id: String) {
        model.set(model.current.filter { $0.id != id })
    }

    private func importSafariExtension(_ candidate: SettingsDiscoveredBrowserExtension) {
        add(BrowserWebExtensionEntry(
            id: candidate.id,
            kind: .safariAppExtension,
            path: candidate.path,
            enabled: true,
            displayName: candidate.displayName
        ))
    }

    private func addUnpackedExtension() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = String(
            localized: "settings.browser.webExtensions.addUnpacked.message",
            defaultValue: "Choose a folder containing an unpacked web extension (manifest.json at its root)."
        )
        guard panel.runModal() == .OK, let url = panel.url else { return }
        add(BrowserWebExtensionEntry(
            id: url.path,
            kind: .unpackedDirectory,
            path: url.path,
            enabled: true,
            displayName: url.lastPathComponent
        ))
    }
}
