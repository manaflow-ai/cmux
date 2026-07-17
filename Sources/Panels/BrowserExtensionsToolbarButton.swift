import AppKit
import SwiftUI

struct BrowserExtensionsToolbarButton: View {
    @Binding var isPresented: Bool
    let panelID: UUID
    let profileID: UUID
    let iconPointSize: CGFloat
    let hitSize: CGFloat
    let loadSnapshot: @MainActor () async -> BrowserWebExtensionsPresentationSnapshot
    let openManager: @MainActor () -> Bool
    let setToolbarPinned: @MainActor (String, Bool) async -> Bool
    let performAction: @MainActor (String, NSView?) -> Bool

    @State private var snapshot = BrowserWebExtensionsPresentationSnapshot.loading
    @State private var isLoadingPresentation = false
    @State private var managerAnchorHolder = BrowserExtensionActionAnchorHolder()
    @State private var actionRefreshTask: Task<Void, Never>?
    @State private var actionRefreshGeneration = 0

    var body: some View {
        HStack(spacing: 0) {
            ForEach(snapshot.extensions.filter { $0.hasAction && $0.isToolbarPinned }) { item in
                BrowserExtensionToolbarActionButton(
                    item: item,
                    iconPointSize: iconPointSize,
                    hitSize: hitSize,
                    performAction: performAction
                )
            }

            managerButton
        }
        .task {
            await refreshSnapshot()
        }
        .onReceive(NotificationCenter.default.publisher(for: .browserWebExtensionActionDidChange)) { notification in
            if let changedProfileID = notification.userInfo?[BrowserWebExtensionsPresentationSnapshot.NotificationKey.profileID] as? UUID,
               changedProfileID != profileID {
                return
            }
            if let changedPanelID = notification.userInfo?[BrowserWebExtensionsPresentationSnapshot.NotificationKey.panelID] as? UUID,
               changedPanelID != panelID {
                return
            }
            if let item = notification.userInfo?[BrowserWebExtensionsPresentationSnapshot.NotificationKey.item]
                as? BrowserWebExtensionsPresentationSnapshot.Item {
                applyActionUpdate(item)
                return
            }
            scheduleActionRefresh()
        }
        .onDisappear {
            actionRefreshTask?.cancel()
        }
    }

    private var managerButton: some View {
        Button {
            if isPresented {
                isPresented = false
                return
            }
            guard !isLoadingPresentation else { return }
            isLoadingPresentation = true
            Task { @MainActor in
                await refreshSnapshot()
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
        .background(BrowserExtensionActionAnchorReader(holder: managerAnchorHolder))
        .disabled(isLoadingPresentation)
        .frame(width: hitSize, height: hitSize, alignment: .center)
        .safeHelp(String(localized: "browser.extensions.title", defaultValue: "Extensions"))
        .accessibilityLabel(String(localized: "browser.extensions.title", defaultValue: "Extensions"))
        .accessibilityIdentifier("BrowserExtensionsButton")
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            BrowserExtensionsPopoverContent(
                snapshot: snapshot,
                openManager: openManager,
                setToolbarPinned: setToolbarPinned,
                performAction: { identifier in
                    isPresented = false
                    return performAction(identifier, managerAnchorHolder.view)
                }
            )
        }
    }

    @MainActor
    private func refreshSnapshot() async {
        snapshot = await loadSnapshot()
    }

    @MainActor
    private func scheduleActionRefresh() {
        actionRefreshGeneration &+= 1
        let generation = actionRefreshGeneration
        actionRefreshTask?.cancel()
        actionRefreshTask = Task { @MainActor in
            // Coalesce action mutations delivered in the same main-actor turn.
            await Task.yield()
            guard !Task.isCancelled else { return }
            let nextSnapshot = await loadSnapshot()
            guard !Task.isCancelled, generation == actionRefreshGeneration else { return }
            snapshot = nextSnapshot
        }
    }

    @MainActor
    private func applyActionUpdate(_ item: BrowserWebExtensionsPresentationSnapshot.Item) {
        guard let index = snapshot.extensions.firstIndex(where: { $0.id == item.id }) else {
            scheduleActionRefresh()
            return
        }
        var extensions = snapshot.extensions
        extensions[index] = item
        snapshot = BrowserWebExtensionsPresentationSnapshot(
            state: snapshot.state,
            extensions: extensions,
            failures: snapshot.failures,
            directoryPath: snapshot.directoryPath
        )
    }
}

@MainActor
private final class BrowserExtensionActionAnchorHolder {
    weak var view: NSView?
}

private struct BrowserExtensionActionAnchorReader: NSViewRepresentable {
    let holder: BrowserExtensionActionAnchorHolder

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        holder.view = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        holder.view = nsView
    }
}

private struct BrowserExtensionToolbarActionButton: View {
    let item: BrowserWebExtensionsPresentationSnapshot.Item
    let iconPointSize: CGFloat
    let hitSize: CGFloat
    let performAction: @MainActor (String, NSView?) -> Bool

    @State private var anchorHolder = BrowserExtensionActionAnchorHolder()

    var body: some View {
        Button {
            _ = performAction(item.id, anchorHolder.view)
        } label: {
            ZStack(alignment: .topTrailing) {
                BrowserExtensionIcon(
                    data: item.iconData,
                    fallbackSystemName: "puzzlepiece.extension",
                    fallbackColor: .secondary
                )
                .frame(width: iconPointSize + 3, height: iconPointSize + 3)

                if !item.badgeText.isEmpty {
                    Text(item.badgeText)
                        .font(.system(size: 8, weight: .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.65)
                        .padding(.horizontal, 3)
                        .frame(minWidth: 10, maxWidth: 20, minHeight: 10)
                        .background(Capsule().fill(Color.accentColor))
                        .foregroundStyle(.white)
                        .offset(x: 5, y: -4)
                }
            }
            .frame(width: hitSize, height: hitSize, alignment: .center)
            .contentShape(Rectangle())
        }
        .buttonStyle(OmnibarAddressButtonStyle())
        .background(BrowserExtensionActionAnchorReader(holder: anchorHolder))
        .disabled(!item.isActionEnabled)
        .opacity(item.isActionEnabled ? 1 : 0.45)
        .safeHelp(item.name)
        .accessibilityLabel(item.name)
        .accessibilityIdentifier("BrowserExtensionToolbarAction-\(item.id)")
    }
}

private struct BrowserExtensionsPopoverContent: View {
    let snapshot: BrowserWebExtensionsPresentationSnapshot
    let openManager: @MainActor () -> Bool
    let setToolbarPinned: @MainActor (String, Bool) async -> Bool
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

            BrowserExtensionsPopoverStatus(
                snapshot: snapshot,
                setToolbarPinned: setToolbarPinned,
                performAction: performAction
            )

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
                    installStatus: installStatus,
                    setToolbarPinned: setToolbarPinned
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

    @MainActor
    private func setToolbarPinned(_ item: BrowserWebExtensionsPresentationSnapshot.Item, _ isPinned: Bool) {
        Task { @MainActor in
            guard await panel.setBrowserWebExtensionToolbarActionPinned(
                isPinned,
                uniqueIdentifier: item.id
            ) else { return }
            snapshot = await panel.browserWebExtensionsPresentationSnapshot()
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
                Text(String(localized: "browser.extensions.manager.subtitle", defaultValue: "Discover and manage WebExtensions for this browser profile."))
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
    let setToolbarPinned: @MainActor (
        BrowserWebExtensionsPresentationSnapshot.Item,
        Bool
    ) -> Void

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
                                item: item,
                                detail: String(localized: "browser.extensions.enabled", defaultValue: "Enabled"),
                                iconData: item.iconData,
                                fallbackIcon: "puzzlepiece.extension",
                                fallbackColor: .secondary,
                                setToolbarPinned: setToolbarPinned
                            )
                            Divider()
                        }
                        ForEach(snapshot.failures) { failure in
                            BrowserInstalledExtensionRow(
                                item: nil,
                                fallbackName: failure.entryName,
                                detail: failure.message,
                                iconData: nil,
                                fallbackIcon: "exclamationmark.triangle.fill",
                                fallbackColor: .orange,
                                setToolbarPinned: { _, _ in }
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
    let item: BrowserWebExtensionsPresentationSnapshot.Item?
    var fallbackName = ""
    let detail: String
    let iconData: Data?
    let fallbackIcon: String
    let fallbackColor: Color
    let setToolbarPinned: @MainActor (
        BrowserWebExtensionsPresentationSnapshot.Item,
        Bool
    ) -> Void

    var body: some View {
        HStack(spacing: 10) {
            BrowserExtensionIcon(
                data: iconData,
                fallbackSystemName: fallbackIcon,
                fallbackColor: fallbackColor
            )
            VStack(alignment: .leading, spacing: 2) {
                Text(item?.name ?? fallbackName).font(.callout.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            if let item, item.hasAction {
                BrowserExtensionToolbarPinButton(
                    item: item,
                    setToolbarPinned: setToolbarPinned
                )
            }
        }
        .padding(12)
    }
}

private struct BrowserExtensionsPopoverStatus: View {
    let snapshot: BrowserWebExtensionsPresentationSnapshot
    let setToolbarPinned: @MainActor (String, Bool) async -> Bool
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
            BrowserExtensionsReadyList(
                snapshot: snapshot,
                setToolbarPinned: setToolbarPinned,
                performAction: performAction
            )
        }
    }
}

private struct BrowserExtensionsReadyList: View {
    let snapshot: BrowserWebExtensionsPresentationSnapshot
    let setToolbarPinned: @MainActor (String, Bool) async -> Bool
    let performAction: @MainActor (String) -> Bool

    var body: some View {
        if snapshot.extensions.isEmpty && snapshot.failures.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text(String(localized: "browser.extensions.empty.title", defaultValue: "No extensions installed"))
                    .font(.callout.weight(.medium))
                Text(
                    String(
                        localized: "browser.extensions.empty.detail",
                        defaultValue: "Use Add Extension to install an unpacked Safari Web Extension or .zip file."
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
                            HStack(spacing: 4) {
                                Button {
                                    _ = performAction(item.id)
                                } label: {
                                    HStack(spacing: 10) {
                                        BrowserExtensionIcon(
                                            data: item.iconData,
                                            fallbackSystemName: "puzzlepiece.extension",
                                            fallbackColor: .secondary
                                        )
                                        Text(item.name)
                                            .lineLimit(1)
                                        Spacer()
                                        Image(systemName: "chevron.right")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("BrowserExtensionAction-\(item.id)")

                                BrowserExtensionToolbarPinButton(item: item) { changedItem, isPinned in
                                    Task { @MainActor in
                                        _ = await setToolbarPinned(changedItem.id, isPinned)
                                    }
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                        } else {
                            HStack(spacing: 10) {
                                BrowserExtensionIcon(
                                    data: item.iconData,
                                    fallbackSystemName: "puzzlepiece.extension",
                                    fallbackColor: .secondary
                                )
                                Text(item.name)
                                    .lineLimit(1)
                                Spacer()
                            }
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

private struct BrowserExtensionToolbarPinButton: View {
    let item: BrowserWebExtensionsPresentationSnapshot.Item
    let setToolbarPinned: @MainActor (
        BrowserWebExtensionsPresentationSnapshot.Item,
        Bool
    ) -> Void

    var body: some View {
        Button {
            setToolbarPinned(item, !item.isToolbarPinned)
        } label: {
            Image(systemName: item.isToolbarPinned ? "pin.fill" : "pin")
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .safeHelp(helpText)
        .accessibilityLabel(helpText)
        .accessibilityIdentifier("BrowserExtensionToolbarPin-\(item.id)")
    }

    private var helpText: String {
        if item.isToolbarPinned {
            return String(
                localized: "browser.extensions.toolbar.unpin",
                defaultValue: "Unpin from Toolbar"
            )
        }
        return String(
            localized: "browser.extensions.toolbar.pin",
            defaultValue: "Pin to Toolbar"
        )
    }
}

private struct BrowserExtensionIcon: View {
    let data: Data?
    let fallbackSystemName: String
    let fallbackColor: Color

    var body: some View {
        Group {
            if let data, let image = NSImage(data: data) {
                Image(nsImage: image)
                    .resizable()
                    .renderingMode(.original)
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: fallbackSystemName)
                    .foregroundStyle(fallbackColor)
            }
        }
        .frame(width: 20, height: 20)
        .accessibilityHidden(true)
    }
}
