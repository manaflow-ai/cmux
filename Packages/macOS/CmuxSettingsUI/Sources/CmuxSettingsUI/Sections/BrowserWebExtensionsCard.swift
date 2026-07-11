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
    private let fileManager: FileManager

    @State private var cardState = BrowserWebExtensionsCardState()
    @State private var loadErrorsByEntryID: [String: String] = [:]

    init(
        model: JSONValueModel<[BrowserWebExtensionEntry]>,
        hostActions: SettingsHostActions,
        fileManager: FileManager = .default
    ) {
        self.model = model
        self.hostActions = hostActions
        self.fileManager = fileManager
    }

    var body: some View {
        let entries = cardState.effectiveEntries(observed: model.current)
        let enabledByID = effectiveEnabledByID(for: entries)
        SettingsCard {
            headerRow
            if supported {
                ForEach(entries) { entry in
                    SettingsCardDivider()
                    entryRow(entry, isEnabled: enabledByID[entry.id] ?? entry.enabled)
                }
                if cardState.shouldShowEmptyState(
                    entries: entries,
                    hasObservedValue: model.hasObservedValue
                ) {
                    SettingsCardDivider()
                    emptyRow
                }
            }
        }
        .task {
            model.startObserving()
            let discovered = await hostActions.discoverBrowserWebExtensions()
            guard !Task.isCancelled else { return }
            cardState.completeDiscovery(discovered)
        }
        .task {
            for await loadErrors in hostActions.browserWebExtensionLoadErrorUpdates() {
                loadErrorsByEntryID = loadErrors
            }
        }
        .onChange(of: model.current) { _, current in
            cardState.reconcileObservedEntries(current)
        }
        .onChange(of: model.writeResultRevision) { _, _ in
            cardState.reconcileWriteResult(
                completedWriteID: model.lastCompletedWriteID,
                failed: model.lastWriteError != nil,
                observedEntries: model.current
            )
        }
    }

    private var supported: Bool {
        hostActions.browserWebExtensionsSupported()
    }

    private var effectiveEntries: [BrowserWebExtensionEntry] {
        cardState.effectiveEntries(observed: model.current)
    }

    /// Discovered Safari extensions not yet added, offered by the Import menu.
    private var importableExtensions: [SettingsDiscoveredBrowserExtension] {
        guard cardState.canUseImportMenu(
            supported: supported,
            hasObservedValue: model.hasObservedValue
        ) else { return [] }
        let entries = effectiveEntries
        let addedIDs = Set(entries.map(\.id))
        let addedResourcePaths = Set(entries.map { standardizedResourcePath(for: $0) })
        return cardState.discovered.filter { candidate in
            !addedIDs.contains(candidate.id)
                && !addedResourcePaths.contains(standardizedSafariAppExtensionResourcePath(candidate.path))
        }
    }

    private var headerRow: some View {
        return SettingsCardRow(
            configurationReview: .json("browser.webExtensions"),
            searchAnchorID: "setting:browser:web-extensions",
            String(localized: "settings.browser.webExtensions", defaultValue: "Extensions"),
            subtitle: headerSubtitle
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
                .disabled(!supported || !model.hasObservedValue)
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
        .disabled(!cardState.canUseImportMenu(
            supported: supported,
            hasObservedValue: model.hasObservedValue
        ))
        .accessibilityIdentifier("BrowserWebExtensionsImportMenu")
    }

    private var headerSubtitle: String {
        if !supported {
            return String(
                localized: "settings.browser.webExtensions.unsupported",
                defaultValue: "Web extensions require macOS 15.4 or later."
            )
        }
        if cardState.hasWriteError {
            return String(
                localized: "settings.browser.webExtensions.saveFailed.subtitle",
                defaultValue: "Couldn’t save extension changes. Check cmux.json and try again."
            )
        }
        return String(
            localized: "settings.browser.webExtensions.subtitle",
            defaultValue: "Safari web extensions from installed apps, or unpacked extension folders."
        )
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

    private func entryRow(_ entry: BrowserWebExtensionEntry, isEnabled: Bool) -> some View {
        let detail = entry.kind == .safariAppExtension ? entry.id : entry.path
        let subtitle = if loadErrorsByEntryID[entry.id] == nil {
            detail
        } else {
            String.localizedStringWithFormat(
                String(
                    localized: "settings.browser.webExtensions.loadFailed.subtitle",
                    defaultValue: "%@ — Extension error. Disable and re-enable to retry, or remove it."
                ),
                detail
            )
        }
        return SettingsCardRow(
            configurationReview: .json("browser.webExtensions"),
            entry.displayName ?? (entry.path as NSString).lastPathComponent,
            subtitle: subtitle
        ) {
            HStack(spacing: 8) {
                Toggle("", isOn: Binding(
                    get: { isEnabled },
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

    private func setEnabled(_ enabled: Bool, id: String) {
        updateEntries { entries in
            guard let index = entries.firstIndex(where: { $0.id == id }) else { return false }
            let targetPath = standardizedResourcePath(for: entries[index])
            entries[index].enabled = enabled
            for candidateIndex in entries.indices where candidateIndex != index {
                if standardizedResourcePath(for: entries[candidateIndex]) == targetPath {
                    entries[candidateIndex].enabled = false
                }
            }
            return true
        }
    }

    private func add(_ entry: BrowserWebExtensionEntry) {
        guard model.hasObservedValue else { return }
        var entries = effectiveEntries
        guard !entries.contains(where: { $0.id == entry.id }) else {
            presentDuplicateExtensionAlert(for: entry)
            return
        }
        let entryResourcePath = standardizedResourcePath(for: entry)
        guard !entries.contains(where: { standardizedResourcePath(for: $0) == entryResourcePath }) else {
            presentDuplicateExtensionAlert(for: entry)
            return
        }
        entries.append(entry)
        commitEntries(entries)
    }

    private func remove(id: String) {
        updateEntries { entries in
            let originalCount = entries.count
            entries.removeAll { $0.id == id }
            return entries.count != originalCount
        }
    }

    private func updateEntries(_ update: (inout [BrowserWebExtensionEntry]) -> Bool) {
        guard model.hasObservedValue else { return }
        var entries = effectiveEntries
        guard update(&entries) else { return }
        commitEntries(entries)
    }

    private func commitEntries(_ entries: [BrowserWebExtensionEntry]) {
        cardState.beginWrite(entries: entries, writeID: model.set(entries))
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
        let manifestURL = url.appendingPathComponent("manifest.json", isDirectory: false)
        guard fileManager.fileExists(atPath: manifestURL.path) else {
            presentMissingManifestAlert(for: url)
            return
        }
        add(BrowserWebExtensionEntry(
            id: url.path,
            kind: .unpackedDirectory,
            path: url.path,
            enabled: true,
            displayName: url.lastPathComponent
        ))
    }

    private func presentMissingManifestAlert(for url: URL) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(
            localized: "settings.browser.webExtensions.addUnpacked.missingManifest.title",
            defaultValue: "Missing manifest.json"
        )
        alert.informativeText = String.localizedStringWithFormat(
            String(
                localized: "settings.browser.webExtensions.addUnpacked.missingManifest.message",
                defaultValue: "“%@” is not an unpacked web extension. Choose a folder with manifest.json at its root."
            ),
            url.lastPathComponent
        )
        alert.addButton(withTitle: String(localized: "common.ok", defaultValue: "OK"))
        alert.runModal()
    }

    private func presentDuplicateExtensionAlert(for entry: BrowserWebExtensionEntry) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = String(
            localized: "settings.browser.webExtensions.duplicate.title",
            defaultValue: "Extension Already Added"
        )
        let displayName = entry.displayName ?? (entry.path as NSString).lastPathComponent
        alert.informativeText = String.localizedStringWithFormat(
            String(
                localized: "settings.browser.webExtensions.duplicate.message",
                defaultValue: "“%@” is already in the extensions list."
            ),
            displayName
        )
        alert.addButton(withTitle: String(localized: "common.ok", defaultValue: "OK"))
        alert.runModal()
    }

    private func effectiveEnabledByID(for entries: [BrowserWebExtensionEntry]) -> [String: Bool] {
        var seenEnabledPaths = Set<String>()
        var result: [String: Bool] = [:]
        for entry in entries {
            let path = standardizedResourcePath(for: entry)
            let isFirstEnabledEntryForPath = entry.enabled && seenEnabledPaths.insert(path).inserted
            result[entry.id] = isFirstEnabledEntryForPath
        }
        return result
    }

    private func standardizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path).browserWebExtensionStandardizedPath
    }

    private func standardizedResourcePath(for entry: BrowserWebExtensionEntry) -> String {
        entry.standardizedResourceRootPath
    }

    private func standardizedSafariAppExtensionResourcePath(_ path: String) -> String {
        URL(fileURLWithPath: path).browserWebExtensionSafariResourceRootPath
    }
}
