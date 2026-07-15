import SwiftUI

struct BrowserExtensionsToolbarButton: View {
    @Binding var isPresented: Bool
    let iconPointSize: CGFloat
    let hitSize: CGFloat
    let loadSnapshot: @MainActor () async -> BrowserWebExtensionsPresentationSnapshot
    let openManager: @MainActor () -> Bool
    let performAction: @MainActor (String) -> Bool

    @State private var snapshot = BrowserWebExtensionsPresentationSnapshot.loading
    @State private var isLoadingPresentation = false

    var body: some View {
        Button {
            if isPresented {
                isPresented = false
                return
            }
            guard !isLoadingPresentation else { return }
            isLoadingPresentation = true
            Task { @MainActor in
                snapshot = await loadSnapshot()
                isLoadingPresentation = false
                isPresented = true
            }
        } label: {
            CmuxSystemSymbolImage(
                systemName: "puzzlepiece.extension",
                pointSize: iconPointSize,
                weight: .medium
            )
            .foregroundStyle(Color(nsColor: .secondaryLabelColor))
            .frame(width: hitSize, height: hitSize, alignment: .center)
            .contentShape(Rectangle())
        }
        .buttonStyle(OmnibarAddressButtonStyle())
        .disabled(isLoadingPresentation)
        .frame(width: hitSize, height: hitSize, alignment: .center)
        .safeHelp(String(localized: "browser.extensions.title", defaultValue: "Extensions"))
        .accessibilityLabel(String(localized: "browser.extensions.title", defaultValue: "Extensions"))
        .accessibilityIdentifier("BrowserExtensionsButton")
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            BrowserExtensionsPopoverContent(
                snapshot: snapshot,
                openManager: openManager,
                performAction: { identifier in
                    isPresented = false
                    return performAction(identifier)
                }
            )
        }
    }
}

private struct BrowserExtensionsPopoverContent: View {
    let snapshot: BrowserWebExtensionsPresentationSnapshot
    let openManager: @MainActor () -> Bool
    let performAction: @MainActor (String) -> Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Label(
                String(localized: "browser.extensions.title", defaultValue: "Extensions"),
                systemImage: "puzzlepiece.extension"
            )
            .font(.headline)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider()

            BrowserExtensionsPopoverStatus(snapshot: snapshot, performAction: performAction)

            if snapshot.state == .ready {
                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Button {
                        _ = openManager()
                    } label: {
                        Label(
                            String(
                                localized: "browser.extensions.manage",
                                defaultValue: "Manage Extensions"
                            ),
                            systemImage: "puzzlepiece.extension"
                        )
                    }
                }
                .padding(12)
            }
        }
        .frame(width: 340)
        .accessibilityIdentifier("BrowserExtensionsPopover")
    }
}

private enum BrowserExtensionInstallStatus: Equatable {
    case installing
    case installed(String)
    case failed(String)
}

private struct BrowserExtensionCatalogItem: Identifiable {
    let entry: BrowserWebExtensionCatalogEntry
    let name: String
    let detail: String
    let icon: String

    var id: String { entry.id }
}

struct BrowserExtensionsManagerPage: View {
    @ObservedObject var panel: BrowserPanel
    let appearance: PanelAppearance
    @State private var snapshot = BrowserWebExtensionsPresentationSnapshot.loading
    @State private var installStatus: BrowserExtensionInstallStatus?
    @State private var installingCatalogID: String?
    @State private var catalogSearch = ""

    private var commonExtensions: [BrowserExtensionCatalogItem] {
        BrowserWebExtensionCatalog.verifiedEntries.compactMap { entry in
            guard entry.id == "video-speed-controller" else { return nil }
            return BrowserExtensionCatalogItem(
                entry: entry,
                name: String(
                    localized: "browser.extensions.catalog.videoSpeedController.name",
                    defaultValue: "Video Speed Controller"
                ),
                detail: String(
                    localized: "browser.extensions.catalog.videoSpeedController.detail",
                    defaultValue: "Control HTML5 video speed with shortcuts"
                ),
                icon: "gauge.with.dots.needle.67percent"
            )
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                BrowserExtensionsManagerHeader(
                    isDisabled: installStatus == .installing || snapshot.state != .ready,
                    chooseExtension: chooseExtension
                )
                BrowserExtensionCatalogSection(
                    items: commonExtensions,
                    snapshot: snapshot,
                    installingCatalogID: installingCatalogID,
                    searchText: $catalogSearch,
                    install: installCatalogExtension
                )
                BrowserExtensionsInstalledSection(
                    snapshot: snapshot,
                    installStatus: installStatus
                )
            }
            .frame(maxWidth: 880, alignment: .leading)
            .padding(.horizontal, 32)
            .padding(.vertical, 28)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .background(Color(nsColor: appearance.backgroundColor))
        .environment(\.colorScheme, cmuxReadableColorScheme(for: appearance.backgroundColor))
        .accessibilityIdentifier("BrowserExtensionsManagerPage")
        .task {
            snapshot = await panel.browserWebExtensionsPresentationSnapshot()
        }
    }

    @MainActor
    private func chooseExtension() {
        let picker = NSOpenPanel()
        picker.title = String(localized: "browser.extensions.install.pickerTitle", defaultValue: "Choose a WebExtension")
        picker.prompt = String(localized: "browser.extensions.install.pickerPrompt", defaultValue: "Add Extension")
        picker.message = String(localized: "browser.extensions.install.pickerMessage", defaultValue: "Choose an unpacked extension folder or a ZIP archive.")
        picker.canChooseDirectories = true
        picker.canChooseFiles = true
        picker.allowsMultipleSelection = false
        picker.begin { response in
            guard response == .OK, let source = picker.url else { return }
            Task { @MainActor in
                installStatus = .installing
                do {
                    let receipt = try await panel.installBrowserWebExtension(from: source)
                    installStatus = .installed(receipt.name)
                    snapshot = await panel.browserWebExtensionsPresentationSnapshot()
                } catch {
                    installStatus = .failed(error.localizedDescription)
                }
            }
        }
    }

    @MainActor
    private func installCatalogExtension(_ item: BrowserExtensionCatalogItem) {
        guard installingCatalogID == nil else { return }
        installingCatalogID = item.id
        installStatus = .installing
        Task { @MainActor in
            defer { installingCatalogID = nil }
            do {
                let receipt = try await panel.installBrowserWebExtension(item.entry)
                installStatus = .installed(receipt.name)
                snapshot = await panel.browserWebExtensionsPresentationSnapshot()
            } catch {
                installStatus = .failed(error.localizedDescription)
            }
        }
    }
}

private struct BrowserExtensionsManagerHeader: View {
    let isDisabled: Bool
    let chooseExtension: @MainActor () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: "puzzlepiece.extension.fill")
                .font(.title.weight(.semibold))
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 3) {
                Text(String(localized: "browser.extensions.manager.title", defaultValue: "Browser Extensions"))
                    .font(.title2.weight(.semibold))
                Text(String(localized: "browser.extensions.manager.subtitle", defaultValue: "Discover and manage WebExtensions for every cmux browser pane."))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Menu {
                Button(action: chooseExtension) {
                    Label(
                        String(localized: "browser.extensions.install.action", defaultValue: "Add from Disk…"),
                        systemImage: "internaldrive"
                    )
                }
            } label: {
                Label(
                    String(localized: "browser.extensions.add", defaultValue: "Add Extension"),
                    systemImage: "plus"
                )
            }
            .controlSize(.regular)
            .disabled(isDisabled)
            .accessibilityIdentifier("BrowserExtensionsAddFromDiskButton")
        }
    }
}

private struct BrowserExtensionCatalogSection: View {
    let items: [BrowserExtensionCatalogItem]
    let snapshot: BrowserWebExtensionsPresentationSnapshot
    let installingCatalogID: String?
    @Binding var searchText: String
    let install: @MainActor (BrowserExtensionCatalogItem) -> Void

    private var filteredItems: [BrowserExtensionCatalogItem] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return items }
        return items.filter {
            $0.name.localizedCaseInsensitiveContains(query)
                || $0.detail.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(String(localized: "browser.extensions.store.title", defaultValue: "Extension Store"))
                .font(.headline)

            TextField(
                String(localized: "browser.extensions.store.search", defaultValue: "Search extensions"),
                text: $searchText
            )
            .textFieldStyle(.roundedBorder)
            .accessibilityIdentifier("BrowserExtensionsCatalogSearchField")

            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(filteredItems) { item in
                    BrowserExtensionCatalogRow(
                        item: item,
                        isInstalled: snapshot.extensions.contains {
                            $0.id == item.entry.installedExtensionIdentifier
                        },
                        isInstalling: installingCatalogID == item.id,
                        install: install
                    )
                    Divider()
                }
            }

            if filteredItems.isEmpty {
                ContentUnavailableView.search(text: searchText)
            }

            Text(String(localized: "browser.extensions.catalog.explanation", defaultValue: "Every listed package is version-pinned and integrity-checked before installation."))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct BrowserExtensionCatalogRow: View {
    let item: BrowserExtensionCatalogItem
    let isInstalled: Bool
    let isInstalling: Bool
    let install: @MainActor (BrowserExtensionCatalogItem) -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: item.icon)
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(.callout.weight(.medium))
                Text(item.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 12)
            if isInstalled {
                Text(String(localized: "browser.extensions.store.installed", defaultValue: "Installed"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if isInstalling {
                ProgressView()
                    .controlSize(.small)
            } else {
                Button(String(localized: "browser.extensions.store.get", defaultValue: "Get")) {
                    install(item)
                }
                .controlSize(.small)
                .accessibilityIdentifier("BrowserExtensionsCatalogGet-\(item.id)")
            }
        }
        .padding(.vertical, 10)
    }
}

private struct BrowserExtensionsInstalledSection: View {
    let snapshot: BrowserWebExtensionsPresentationSnapshot
    let installStatus: BrowserExtensionInstallStatus?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(String(localized: "browser.extensions.installed", defaultValue: "Installed"))
                .font(.headline)
            switch snapshot.state {
            case .unsupported:
                BrowserExtensionStatusRow(
                    text: String(localized: "browser.extensions.unsupported", defaultValue: "Browser extensions require macOS 15.4 or later."),
                    icon: "exclamationmark.triangle"
                )
            case .loading:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(String(localized: "browser.extensions.loading", defaultValue: "Loading extensions…"))
                        .foregroundStyle(.secondary)
                }
            case .ready:
                if snapshot.extensions.isEmpty && snapshot.failures.isEmpty {
                    BrowserExtensionStatusRow(
                        text: String(localized: "browser.extensions.empty.title", defaultValue: "No extensions installed"),
                        icon: "puzzlepiece.extension"
                    )
                } else {
                    VStack(spacing: 0) {
                        ForEach(snapshot.extensions) { item in
                            BrowserInstalledExtensionRow(
                                name: item.name,
                                detail: String(localized: "browser.extensions.enabled", defaultValue: "Enabled"),
                                icon: "checkmark.circle.fill",
                                color: .green
                            )
                            Divider()
                        }
                        ForEach(snapshot.failures) { failure in
                            BrowserInstalledExtensionRow(
                                name: failure.entryName,
                                detail: failure.message,
                                icon: "exclamationmark.triangle.fill",
                                color: .orange
                            )
                            Divider()
                        }
                    }
                }
            }

            if let installStatus {
                switch installStatus {
                case .installing:
                    Label(String(localized: "browser.extensions.install.installing", defaultValue: "Installing extension…"), systemImage: "arrow.down.circle")
                        .foregroundStyle(.secondary)
                case .installed(let name):
                    Label(
                        String(localized: "browser.extensions.install.success", defaultValue: "Installed \(name)."),
                        systemImage: "checkmark.circle.fill"
                    )
                    .foregroundStyle(.green)
                case .failed(let message):
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
            }

            Text(String(localized: "browser.extensions.install.trust", defaultValue: "Only add extensions you trust. cmux grants the permissions and website access declared in the extension manifest."))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct BrowserExtensionStatusRow: View {
    let text: String
    let icon: String

    var body: some View {
        Label(text, systemImage: icon)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 12)
            .overlay(alignment: .bottom) { Divider() }
    }
}

private struct BrowserInstalledExtensionRow: View {
    let name: String
    let detail: String
    let icon: String
    let color: Color

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(color)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.callout.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
        }
        .padding(12)
    }
}

private struct BrowserExtensionsPopoverStatus: View {
    let snapshot: BrowserWebExtensionsPresentationSnapshot
    let performAction: @MainActor (String) -> Bool

    var body: some View {
        switch snapshot.state {
        case .unsupported:
            Text(
                String(
                    localized: "browser.extensions.unsupported",
                    defaultValue: "Browser extensions require macOS 15.4 or later."
                )
            )
            .foregroundStyle(.secondary)
            .padding(12)
        case .loading:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text(String(localized: "browser.extensions.loading", defaultValue: "Loading extensions…"))
                    .foregroundStyle(.secondary)
            }
            .padding(12)
        case .ready:
            BrowserExtensionsReadyList(snapshot: snapshot, performAction: performAction)
        }
    }
}

private struct BrowserExtensionsReadyList: View {
    let snapshot: BrowserWebExtensionsPresentationSnapshot
    let performAction: @MainActor (String) -> Bool

    var body: some View {
        if snapshot.extensions.isEmpty && snapshot.failures.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text(String(localized: "browser.extensions.empty.title", defaultValue: "No extensions installed"))
                    .font(.callout.weight(.medium))
                Text(
                    String(
                        localized: "browser.extensions.empty.detail",
                        defaultValue: "Add an unpacked Safari Web Extension or .zip file to the extensions folder."
                    )
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(12)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(snapshot.extensions) { item in
                        if item.hasAction {
                            Button {
                                _ = performAction(item.id)
                            } label: {
                                HStack {
                                    Label(item.name, systemImage: "puzzlepiece.extension")
                                        .lineLimit(1)
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .accessibilityIdentifier("BrowserExtensionAction-\(item.id)")
                        } else {
                            Label(item.name, systemImage: "puzzlepiece.extension")
                                .lineLimit(1)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                        }
                    }

                    ForEach(snapshot.failures) { failure in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(failure.entryName)
                                    .lineLimit(1)
                                Text(failure.message)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                    }
                }
            }
            .frame(maxHeight: 280)
        }
    }
}
