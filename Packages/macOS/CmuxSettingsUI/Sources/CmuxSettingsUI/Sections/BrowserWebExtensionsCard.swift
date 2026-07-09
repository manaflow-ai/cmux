import AppKit
import CmuxSettings
import SwiftUI
import UniformTypeIdentifiers

/// **Extensions** card in the Browser section.
///
/// Lists Safari web extensions installed on this Mac (discovered through the
/// host) and unpacked WebExtension directories the user added, each with an
/// enable toggle. State persists under `browser.webExtensions`; the host
/// observes that key and loads/unloads extensions live.
@MainActor
struct BrowserWebExtensionsCard: View {
    let model: JSONValueModel<[BrowserWebExtensionEntry]>
    let hostActions: SettingsHostActions

    @State private var discovered: [SettingsDiscoveredBrowserExtension] = []

    var body: some View {
        SettingsCard {
            headerRow
            if supported {
                ForEach(discovered) { candidate in
                    SettingsCardDivider()
                    discoveredRow(candidate)
                }
                ForEach(unpackedEntries) { entry in
                    SettingsCardDivider()
                    unpackedRow(entry)
                }
                if discovered.isEmpty && unpackedEntries.isEmpty {
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

    private var unpackedEntries: [BrowserWebExtensionEntry] {
        model.current.filter { $0.kind == .unpackedDirectory }
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

    private var emptyRow: some View {
        SettingsCardRow(
            configurationReview: .settingsOnly,
            String(
                localized: "settings.browser.webExtensions.empty",
                defaultValue: "No Safari web extensions found on this Mac"
            ),
            subtitle: String(
                localized: "settings.browser.webExtensions.empty.subtitle",
                defaultValue: "Install an app that bundles one (Bitwarden, AdGuard, …) or add an unpacked extension folder."
            )
        ) {
            EmptyView()
        }
    }

    private func discoveredRow(_ candidate: SettingsDiscoveredBrowserExtension) -> some View {
        SettingsCardRow(
            configurationReview: .json("browser.webExtensions"),
            candidate.displayName ?? candidate.id,
            subtitle: candidate.version.map { "\(candidate.id) · \($0)" } ?? candidate.id
        ) {
            Toggle("", isOn: Binding(
                get: { isEnabled(candidate.id) },
                set: { setEnabled($0, id: candidate.id, kind: .safariAppExtension, path: candidate.path) }
            ))
            .labelsHidden()
            .controlSize(.small)
            .accessibilityIdentifier("BrowserWebExtensionToggle-\(candidate.id)")
        }
    }

    private func unpackedRow(_ entry: BrowserWebExtensionEntry) -> some View {
        SettingsCardRow(
            configurationReview: .json("browser.webExtensions"),
            (entry.path as NSString).lastPathComponent,
            subtitle: entry.path
        ) {
            HStack(spacing: 8) {
                Toggle("", isOn: Binding(
                    get: { isEnabled(entry.id) },
                    set: { setEnabled($0, id: entry.id, kind: .unpackedDirectory, path: entry.path) }
                ))
                .labelsHidden()
                .controlSize(.small)
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

    private func setEnabled(_ enabled: Bool, id: String, kind: BrowserWebExtensionEntry.Kind, path: String) {
        var entries = model.current
        if let index = entries.firstIndex(where: { $0.id == id }) {
            entries[index].enabled = enabled
            entries[index].path = path
        } else {
            entries.append(BrowserWebExtensionEntry(id: id, kind: kind, path: path, enabled: enabled))
        }
        model.set(entries)
    }

    private func remove(id: String) {
        model.set(model.current.filter { $0.id != id })
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
        let path = url.path
        setEnabled(true, id: path, kind: .unpackedDirectory, path: path)
    }
}
