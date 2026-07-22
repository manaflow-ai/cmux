import AppKit
import CmuxBrowser
import SwiftUI

struct BrowserExtensionsToolbarButton: View {
    @Binding var isPresented: Bool
    let panelID: UUID
    let profileID: UUID
    let iconPointSize: CGFloat
    let hitSize: CGFloat
    let loadSnapshot: @MainActor () async -> BrowserWebExtensionsPresentationSnapshot
    let updates: @MainActor () -> AsyncStream<BrowserWebExtensionUpdate>
    let openManager: @MainActor () -> Bool
    let setToolbarPinned: @MainActor (String, Bool) async -> Bool
    let performAction: @MainActor (String, NSView?) -> Bool

    @State private var snapshot = BrowserWebExtensionsPresentationSnapshot.loading
    @State private var isLoadingPresentation = false
    @State private var managerAnchorHolder = BrowserExtensionActionAnchorHolder()
    @State private var actionRefreshTask: Task<Void, Never>?
    @State private var actionRefreshGeneration = 0
    @State private var interactionError: String?

    var body: some View {
        HStack(spacing: 0) {
            ForEach(snapshot.extensions.filter { $0.hasAction && $0.isToolbarPinned }) { item in
                BrowserExtensionToolbarActionButton(
                    item: item,
                    iconPointSize: iconPointSize,
                    hitSize: hitSize,
                    performAction: performToolbarAction
                )
            }

            managerButton
        }
        .task {
            await refreshSnapshot()
            for await update in updates() {
                guard !Task.isCancelled else { return }
                switch update {
                case .actionChanged(let actionUpdate):
                    guard actionUpdate.profileID == profileID,
                          actionUpdate.panelID == nil || actionUpdate.panelID == panelID else {
                        continue
                    }
                    if let item = actionUpdate.item {
                        applyActionUpdate(item)
                    } else {
                        scheduleActionRefresh()
                    }
                case .snapshotInvalidated(let changedProfileID):
                    if changedProfileID == profileID {
                        scheduleActionRefresh()
                    }
                case .phaseChanged(let phase):
                    if phase == .ready || {
                        if case .degraded = phase { return true }
                        return false
                    }() {
                        scheduleActionRefresh()
                    }
                case .navigationReleased, .navigationCancelled, .permissionRequested:
                    continue
                }
            }
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
        .popover(
            isPresented: $isPresented,
            arrowEdge: BrowserExtensionPopoverMetrics.managerArrowEdge
        ) {
            BrowserExtensionsPopoverContent(
                snapshot: snapshot,
                interactionError: interactionError,
                openManager: openManager,
                setToolbarPinned: { identifier, isPinned in
                    let succeeded = await setToolbarPinned(identifier, isPinned)
                    interactionError = succeeded ? nil : String(
                        localized: "browser.extensions.toolbar.pinFailed",
                        defaultValue: "The toolbar pin could not be saved. Try again."
                    )
                    return succeeded
                },
                performAction: { identifier in
                    let succeeded = performAction(identifier, managerAnchorHolder.view)
                    if succeeded {
                        interactionError = nil
                        isPresented = false
                    } else {
                        interactionError = String(
                            localized: "browser.extensions.action.unavailableForTab",
                            defaultValue: "The extension action is no longer available for this tab."
                        )
                    }
                    return succeeded
                }
            )
        }
    }

    @MainActor
    private func performToolbarAction(_ identifier: String, _ anchorView: NSView?) -> Bool {
        let succeeded = performAction(identifier, anchorView)
        if succeeded {
            interactionError = nil
        } else {
            interactionError = String(
                localized: "browser.extensions.action.unavailableForTab",
                defaultValue: "The extension action is no longer available for this tab."
            )
            isPresented = true
        }
        return succeeded
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
    private func applyActionUpdate(_ item: BrowserWebExtensionPresentationItem) {
        guard let index = snapshot.extensions.firstIndex(where: { $0.id == item.id }) else {
            scheduleActionRefresh()
            return
        }
        var extensions = snapshot.extensions
        extensions[index] = item
        snapshot = BrowserWebExtensionsPresentationSnapshot(
            state: snapshot.state,
            extensions: extensions,
            failures: snapshot.failures
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
    let item: BrowserWebExtensionPresentationItem
    let iconPointSize: CGFloat
    let hitSize: CGFloat
    let performAction: @MainActor (String, NSView?) -> Bool

    @State private var anchorHolder = BrowserExtensionActionAnchorHolder()

    var body: some View {
        Button {
            _ = performAction(item.id, anchorHolder.view)
        } label: {
            ZStack(alignment: .topTrailing) {
                if item.isAwaitingPopup {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: iconPointSize + 3, height: iconPointSize + 3)
                } else if item.actionFailure != nil {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: BrowserExtensionIconMetrics.toolbarContentSize(
                            iconPointSize: iconPointSize
                        )))
                        .foregroundStyle(.orange)
                        .frame(width: iconPointSize + 3, height: iconPointSize + 3)
                } else {
                    BrowserExtensionIcon(
                        data: item.iconData,
                        fallbackSystemName: "puzzlepiece.extension",
                        fallbackColor: .secondary,
                        size: BrowserExtensionIconMetrics.toolbarContentSize(
                            iconPointSize: iconPointSize
                        )
                    )
                    .frame(width: iconPointSize + 3, height: iconPointSize + 3)
                }

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
        .safeHelp(actionHelp)
        .accessibilityLabel(actionHelp)
        .accessibilityIdentifier("BrowserExtensionToolbarAction-\(item.id)")
    }

    private var actionHelp: String {
        switch item.actionFailure {
        case .popupTimedOut:
            String(
                localized: "browser.extensions.action.popupTimedOut.retry",
                defaultValue: "The extension popup did not open. Click to retry."
            )
        case .actionUnavailable:
            String(
                localized: "browser.extensions.action.unavailableForTab",
                defaultValue: "The extension action is no longer available for this tab."
            )
        case .toolbarPinFailed:
            String(
                localized: "browser.extensions.toolbar.pinFailed",
                defaultValue: "The toolbar pin could not be saved. Try again."
            )
        case nil:
            item.name
        }
    }
}

private struct BrowserExtensionsPopoverContent: View {
    let snapshot: BrowserWebExtensionsPresentationSnapshot
    let interactionError: String?
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

            if let interactionError {
                Label(interactionError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)

                Divider()
            }

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
    case upToDate
    case failed(String)
}

private struct BrowserExtensionCatalogItem: Identifiable {
    let entry: BrowserWebExtensionCatalogEntry
    let name: String
    let detail: String
    let icon: String

    var id: String { entry.id }
}

struct BrowserExtensionLocalAppItem: Identifiable {
    let id: String
    let name: String
    let detail: String
    let icon: String
    let sourceURL: URL
    let installedManagementID: String
}

private struct BrowserExtensionExternalAppItem: Identifiable {
    let id: String
    let name: String
    let detail: String
    let icon: String
    let appStoreURL: URL
}

struct BrowserExtensionsManagerPage: View {
    @ObservedObject var panel: BrowserPanel
    let appearance: PanelAppearance
    @State private var snapshot = BrowserWebExtensionsPresentationSnapshot.loading
    @State private var installStatus: BrowserExtensionInstallStatus?
    @State private var installingCatalogID: String?
    @State private var installingLocalAppID: String?
    @State private var catalogSearch = ""
    @State private var availableLocalApps: [BrowserExtensionLocalAppItem] = []
    @State private var preparedInstall: BrowserWebExtensionInstallPreview?
    @State private var pendingPreparedInstallID: UUID?
    @State private var removalCandidate: BrowserWebExtensionPresentationItem?

    static func discoverTrustedLocalApps(
        applicationsDirectories: [URL] = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Applications", isDirectory: true),
        ]
    ) async -> [BrowserExtensionLocalAppItem] {
        let verified = await Task.detached(priority: .utility) {
            let verifier = BrowserWebExtensionCodeSignatureVerifier()
            let trustedBundleIdentifiers = Set(
                BrowserWebExtensionCatalog.production.safariAppIdentities.map(\.appBundleIdentifier)
            )
            let candidates = applicationsDirectories.flatMap { directory in
                ((try? FileManager.default.contentsOfDirectory(
                    at: directory,
                    includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsHiddenFiles]
                )) ?? []).filter { url in
                    url.pathExtension.lowercased() == "app"
                        && Bundle(url: url).flatMap(\.bundleIdentifier)
                            .map(trustedBundleIdentifiers.contains) == true
                }
            }
            return candidates.compactMap { candidate in
                try? verifier.verifyApplication(at: candidate)
            }
        }.value
        return verified.compactMap { verifiedIdentity in
            switch verifiedIdentity.identity.id {
            case "bitwarden-safari-app":
                BrowserExtensionLocalAppItem(
                    id: "bitwarden-safari-app",
                    name: String(
                        localized: "browser.extensions.localApp.bitwarden.name",
                        defaultValue: "Bitwarden"
                    ),
                    detail: String(
                        localized: "browser.extensions.localApp.bitwarden.detail",
                        defaultValue: "Use the Safari extension from the Bitwarden app"
                    ),
                    icon: "lock.shield",
                    sourceURL: verifiedIdentity.containingAppURL,
                    installedManagementID: "com.bitwarden.desktop.safari"
                )
            case "onepassword-safari-app":
                BrowserExtensionLocalAppItem(
                    id: "onepassword-safari-app",
                    name: String(
                        localized: "browser.extensions.localApp.onePassword.name",
                        defaultValue: "1Password for Safari"
                    ),
                    detail: String(
                        localized: "browser.extensions.localApp.onePassword.detail",
                        defaultValue: "Use the signed Safari extension with the 1Password desktop bridge"
                    ),
                    icon: "key.fill",
                    sourceURL: verifiedIdentity.containingAppURL,
                    installedManagementID: "com.1password.safari.extension"
                )
            case "ublock-origin-lite-safari-app":
                BrowserExtensionLocalAppItem(
                    id: "ublock-origin-lite-safari-app",
                    name: String(
                        localized: "browser.extensions.localApp.ublockOriginLite.name",
                        defaultValue: "uBlock Origin Lite"
                    ),
                    detail: String(
                        localized: "browser.extensions.localApp.ublockOriginLite.detail",
                        defaultValue: "Block ads and trackers with the Safari extension"
                    ),
                    icon: "shield.lefthalf.filled",
                    sourceURL: verifiedIdentity.containingAppURL,
                    installedManagementID: "net.raymondhill.uBlock-Origin-Lite.Extension"
                )
            default:
                nil
            }
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private var commonExtensions: [BrowserExtensionCatalogItem] {
        BrowserWebExtensionCatalog.production.verifiedEntries.compactMap { entry in
            switch entry.id {
            default:
                return nil
            }
        }
    }

    private var externalAppRecommendations: [BrowserExtensionExternalAppItem] {
        let installedIDs = Set(availableLocalApps.map(\.id))
        return [
            installedIDs.contains("bitwarden-safari-app") ? nil : BrowserExtensionExternalAppItem(
                id: "bitwarden-app-store",
                name: String(
                    localized: "browser.extensions.externalApp.bitwarden.name",
                    defaultValue: "Bitwarden"
                ),
                detail: String(
                    localized: "browser.extensions.externalApp.bitwarden.detail",
                    defaultValue: "Install the signed Bitwarden app for native desktop integration"
                ),
                icon: "lock.shield",
                appStoreURL: URL(string: "https://apps.apple.com/us/app/bitwarden/id1352778147?mt=12")!
            ),
            installedIDs.contains("onepassword-safari-app") ? nil : BrowserExtensionExternalAppItem(
                id: "onepassword-safari-app-store",
                name: String(
                    localized: "browser.extensions.externalApp.onePassword.name",
                    defaultValue: "1Password for Safari"
                ),
                detail: String(
                    localized: "browser.extensions.externalApp.onePassword.detail",
                    defaultValue: "Install the signed 1Password Safari extension with native desktop integration"
                ),
                icon: "key.fill",
                appStoreURL: URL(string: "https://apps.apple.com/us/app/1password-for-safari/id1569813296?mt=12")!
            ),
            installedIDs.contains("ublock-origin-lite-safari-app") ? nil : BrowserExtensionExternalAppItem(
                id: "ublock-origin-lite-app-store",
                name: String(
                    localized: "browser.extensions.externalApp.ublockOriginLite.name",
                    defaultValue: "uBlock Origin Lite"
                ),
                detail: String(
                    localized: "browser.extensions.externalApp.ublockOriginLite.detail",
                    defaultValue: "Install the signed Safari content blocker from the App Store"
                ),
                icon: "shield.lefthalf.filled",
                appStoreURL: URL(string: "https://apps.apple.com/us/app/ublock-origin-lite/id6745342698?platform=mac")!
            ),
        ].compactMap { $0 }
    }

    static func shouldShowCatalog(entryCount: Int) -> Bool {
        entryCount > 0
    }

    static func isInstalled(
        managementID: String,
        in snapshot: BrowserWebExtensionsPresentationSnapshot
    ) -> Bool {
        installedItem(managementID: managementID, in: snapshot) != nil
    }

    static func installedItem(
        managementID: String,
        in snapshot: BrowserWebExtensionsPresentationSnapshot
    ) -> BrowserWebExtensionPresentationItem? {
        snapshot.extensions.first { $0.managementID == managementID }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                BrowserExtensionsManagerHeader(
                    isDisabled: installStatus == .installing
                        || installingLocalAppID != nil
                        || snapshot.state != .ready,
                    chooseExtension: chooseExtension
                )
                if !availableLocalApps.isEmpty {
                    BrowserExtensionLocalAppsSection(
                        items: availableLocalApps,
                        snapshot: snapshot,
                        installingLocalAppID: installingLocalAppID,
                        install: installLocalAppExtension
                    )
                }
                if !externalAppRecommendations.isEmpty {
                    BrowserExtensionExternalAppsSection(items: externalAppRecommendations)
                }
                if Self.shouldShowCatalog(entryCount: commonExtensions.count) {
                    BrowserExtensionCatalogSection(
                        items: commonExtensions,
                        snapshot: snapshot,
                        installingCatalogID: installingCatalogID,
                        searchText: $catalogSearch,
                        install: installCatalogExtension
                    )
                }
                BrowserExtensionsInstalledSection(
                    snapshot: snapshot,
                    installStatus: installStatus,
                    setToolbarPinned: setToolbarPinned,
                    setEnabled: setEnabled,
                    revokeOptionalPermissions: revokeOptionalPermissions,
                    prepareUpdate: prepareUpdate,
                    requestRemoval: { removalCandidate = $0 }
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
            async let nextSnapshot = panel.browserWebExtensionsPresentationSnapshot()
            async let localApps = Self.discoverTrustedLocalApps()
            snapshot = await nextSnapshot
            availableLocalApps = await localApps
        }
        .sheet(item: $preparedInstall, onDismiss: cancelDismissedPreparedInstall) { preview in
            BrowserExtensionInstallReviewSheet(
                preview: preview,
                cancel: cancelPreparedInstall,
                confirm: confirmPreparedInstall
            )
        }
        .alert(
            String(localized: "browser.extensions.remove.title", defaultValue: "Remove Extension?"),
            isPresented: Binding(
                get: { removalCandidate != nil },
                set: { if !$0 { removalCandidate = nil } }
            ),
            presenting: removalCandidate
        ) { item in
            Button(
                String(localized: "browser.extensions.remove.action", defaultValue: "Remove"),
                role: .destructive
            ) {
                removeExtension(item)
            }
            Button(String(localized: "common.cancel", defaultValue: "Cancel"), role: .cancel) {}
        } message: { item in
            Text(String(
                localized: "browser.extensions.remove.message",
                defaultValue: "Remove \(item.name) and its saved extension data from this browser profile?"
            ))
        }
    }

    @MainActor
    private func chooseExtension() {
        let picker = NSOpenPanel()
        picker.title = String(localized: "browser.extensions.install.pickerTitle", defaultValue: "Choose a WebExtension")
        picker.prompt = String(localized: "browser.extensions.install.pickerPrompt", defaultValue: "Add Extension")
        picker.message = String(
            localized: "browser.extensions.install.pickerMessage",
            defaultValue: "Choose a signed Safari extension app, extension bundle, or unpacked extension folder."
        )
        picker.canChooseDirectories = true
        picker.canChooseFiles = true
        picker.allowsMultipleSelection = false
        picker.begin { response in
            guard response == .OK, let source = picker.url else { return }
            Task { @MainActor in
                installStatus = .installing
                do {
                    presentPreparedInstall(
                        try await panel.prepareBrowserWebExtensionInstall(from: source)
                    )
                    installStatus = nil
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
                presentPreparedInstall(
                    try await panel.prepareBrowserWebExtensionInstall(item.entry)
                )
                installStatus = nil
            } catch {
                installStatus = .failed(error.localizedDescription)
            }
        }
    }

    @MainActor
    private func installLocalAppExtension(_ item: BrowserExtensionLocalAppItem) {
        guard installingLocalAppID == nil else { return }
        installingLocalAppID = item.id
        installStatus = .installing
        Task { @MainActor in
            defer { installingLocalAppID = nil }
            do {
                presentPreparedInstall(
                    try await panel.prepareBrowserWebExtensionInstall(from: item.sourceURL)
                )
                installStatus = nil
            } catch {
                installStatus = .failed(error.localizedDescription)
            }
        }
    }

    @MainActor
    private func presentPreparedInstall(_ preview: BrowserWebExtensionInstallPreview) {
        pendingPreparedInstallID = preview.id
        preparedInstall = preview
    }

    @MainActor
    private func cancelPreparedInstall() {
        let id = pendingPreparedInstallID
        pendingPreparedInstallID = nil
        preparedInstall = nil
        guard let id else { return }
        Task { await panel.cancelPreparedBrowserWebExtensionInstall(id: id) }
    }

    @MainActor
    private func cancelDismissedPreparedInstall() {
        guard let id = pendingPreparedInstallID else { return }
        pendingPreparedInstallID = nil
        Task { await panel.cancelPreparedBrowserWebExtensionInstall(id: id) }
    }

    @MainActor
    private func confirmPreparedInstall(
        _ preview: BrowserWebExtensionInstallPreview,
        _ optionalPermissions: Set<String>,
        _ optionalHosts: Set<String>
    ) {
        guard pendingPreparedInstallID == preview.id else { return }
        installStatus = .installing
        Task { @MainActor in
            do {
                let receipt = try await panel.confirmPreparedBrowserWebExtensionInstall(
                    id: preview.id,
                    grantedOptionalPermissions: optionalPermissions,
                    grantedOptionalHosts: optionalHosts
                )
                pendingPreparedInstallID = nil
                preparedInstall = nil
                installStatus = .installed(receipt.name)
                snapshot = await panel.browserWebExtensionsPresentationSnapshot()
            } catch {
                pendingPreparedInstallID = nil
                preparedInstall = nil
                installStatus = .failed(error.localizedDescription)
            }
        }
    }

    @MainActor
    private func setToolbarPinned(_ item: BrowserWebExtensionPresentationItem, _ isPinned: Bool) {
        Task { @MainActor in
            guard await panel.setBrowserWebExtensionToolbarActionPinned(
                isPinned,
                uniqueIdentifier: item.id
            ) else { return }
            snapshot = await panel.browserWebExtensionsPresentationSnapshot()
        }
    }

    @MainActor
    private func setEnabled(_ item: BrowserWebExtensionPresentationItem, _ isEnabled: Bool) {
        guard let managementID = item.managementID else { return }
        Task { @MainActor in
            do {
                try await panel.setBrowserWebExtensionEnabled(
                    isEnabled,
                    managementID: managementID
                )
                snapshot = await panel.browserWebExtensionsPresentationSnapshot()
            } catch {
                installStatus = .failed(error.localizedDescription)
            }
        }
    }

    @MainActor
    private func revokeOptionalPermissions(_ item: BrowserWebExtensionPresentationItem) {
        guard let managementID = item.managementID else { return }
        Task { @MainActor in
            do {
                try await panel.revokeBrowserWebExtensionOptionalPermissions(
                    managementID: managementID
                )
                snapshot = await panel.browserWebExtensionsPresentationSnapshot()
            } catch {
                installStatus = .failed(error.localizedDescription)
            }
        }
    }

    @MainActor
    private func prepareUpdate(_ item: BrowserWebExtensionPresentationItem) {
        guard let managementID = item.managementID else { return }
        installStatus = .installing
        Task { @MainActor in
            do {
                presentPreparedInstall(
                    try await panel.prepareBrowserWebExtensionUpdate(managementID: managementID)
                )
                installStatus = nil
            } catch {
                if error as? BrowserWebExtensionManagementError == .upToDate {
                    installStatus = .upToDate
                } else {
                    installStatus = .failed(error.localizedDescription)
                }
            }
        }
    }

    @MainActor
    private func removeExtension(_ item: BrowserWebExtensionPresentationItem) {
        removalCandidate = nil
        guard let managementID = item.managementID else { return }
        Task { @MainActor in
            do {
                try await panel.removeBrowserWebExtension(managementID: managementID)
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
                Text(String(localized: "browser.extensions.manager.subtitle", defaultValue: "Extensions are optional and install only when you choose one."))
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

private struct BrowserExtensionLocalAppsSection: View {
    let items: [BrowserExtensionLocalAppItem]
    let snapshot: BrowserWebExtensionsPresentationSnapshot
    let installingLocalAppID: String?
    let install: @MainActor (BrowserExtensionLocalAppItem) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(String(localized: "browser.extensions.localApps.title", defaultValue: "Installed Safari Apps"))
                .font(.headline)

            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(items) { item in
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
                        if let installedItem = BrowserExtensionsManagerPage.installedItem(
                            managementID: item.installedManagementID,
                            in: snapshot
                        ) {
                            Text(installedItem.loadFailure == nil
                                ? String(localized: "browser.extensions.store.installed", defaultValue: "Installed")
                                : String(
                                    localized: "browser.extensions.load.failed.short",
                                    defaultValue: "Needs attention"
                                ))
                                .font(.caption)
                                .foregroundStyle(installedItem.loadFailure == nil
                                    ? Color.secondary
                                    : Color.orange)
                        } else if installingLocalAppID == item.id {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Button(String(localized: "browser.extensions.store.get", defaultValue: "Get")) {
                                install(item)
                            }
                            .controlSize(.small)
                            .accessibilityIdentifier("BrowserExtensionsLocalAppGet-\(item.id)")
                        }
                    }
                    .padding(.vertical, 10)
                    Divider()
                }
            }

            Text(String(
                localized: "browser.extensions.localApps.explanation",
                defaultValue: "cmux connects to the Safari extension only after you choose Get. It never installs one automatically."
            ))
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}

private struct BrowserExtensionExternalAppsSection: View {
    let items: [BrowserExtensionExternalAppItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(String(
                localized: "browser.extensions.recommendedApps.title",
                defaultValue: "Recommended Safari Apps"
            ))
            .font(.headline)

            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(items) { item in
                    HStack(spacing: 12) {
                        Image(systemName: item.icon)
                            .font(.title3)
                            .foregroundStyle(.secondary)
                            .frame(width: 28)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.name).font(.callout.weight(.medium))
                            Text(item.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 12)
                        Link(destination: item.appStoreURL) {
                            Text(String(
                                localized: "browser.extensions.openAppStore",
                                defaultValue: "App Store"
                            ))
                        }
                        .controlSize(.small)
                        .accessibilityIdentifier("BrowserExtensionsAppStore-\(item.id)")
                    }
                    .padding(.vertical, 10)
                    Divider()
                }
            }
        }
    }
}

private struct BrowserExtensionInstallReviewSheet: View {
    let preview: BrowserWebExtensionInstallPreview
    let cancel: @MainActor () -> Void
    let confirm: @MainActor (
        BrowserWebExtensionInstallPreview,
        Set<String>,
        Set<String>
    ) -> Void

    @State private var grantedOptionalPermissions = Set<String>()
    @State private var grantedOptionalHosts = Set<String>()

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text(preview.isUpdate
                    ? String(localized: "browser.extensions.review.updateTitle", defaultValue: "Review Extension Update")
                    : String(localized: "browser.extensions.review.installTitle", defaultValue: "Review Extension"))
                    .font(.title2.weight(.semibold))
                Text("\(preview.name) \(preview.version)")
                    .foregroundStyle(.secondary)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    permissionSection(
                        title: String(
                            localized: "browser.extensions.review.requiredPermissions",
                            defaultValue: "Required Permissions"
                        ),
                        values: preview.requiredPermissions
                    )
                    permissionSection(
                        title: String(
                            localized: "browser.extensions.review.requiredSites",
                            defaultValue: "Required Website Access"
                        ),
                        values: preview.requiredHosts
                    )

                    if !preview.optionalPermissions.isEmpty {
                        optionalSection(
                            title: String(
                                localized: "browser.extensions.review.optionalPermissions",
                                defaultValue: "Optional Permissions"
                            ),
                            values: preview.optionalPermissions,
                            selection: $grantedOptionalPermissions
                        )
                    }
                    if !preview.optionalHosts.isEmpty {
                        optionalSection(
                            title: String(
                                localized: "browser.extensions.review.optionalSites",
                                defaultValue: "Optional Website Access"
                            ),
                            values: preview.optionalHosts,
                            selection: $grantedOptionalHosts
                        )
                    }

                    ForEach(preview.capabilityNotices, id: \.rawValue) { notice in
                        Label(capabilityText(notice), systemImage: "exclamationmark.triangle.fill")
                            .font(.callout)
                            .foregroundStyle(.orange)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack {
                Spacer()
                Button(String(localized: "common.cancel", defaultValue: "Cancel"), action: cancel)
                    .keyboardShortcut(.cancelAction)
                Button(preview.isUpdate
                    ? String(localized: "browser.extensions.review.update", defaultValue: "Update")
                    : String(localized: "browser.extensions.review.install", defaultValue: "Install")) {
                    confirm(preview, grantedOptionalPermissions, grantedOptionalHosts)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 560, height: 520)
        .interactiveDismissDisabled()
        .accessibilityIdentifier("BrowserExtensionInstallReviewSheet")
    }

    @ViewBuilder
    private func permissionSection(title: String, values: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            if values.isEmpty {
                Text(String(localized: "browser.extensions.review.none", defaultValue: "None"))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(values, id: \.self) { value in
                    Label(value, systemImage: "checkmark.circle")
                        .textSelection(.enabled)
                }
            }
        }
    }

    @ViewBuilder
    private func optionalSection(
        title: String,
        values: [String],
        selection: Binding<Set<String>>
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            ForEach(values, id: \.self) { value in
                Toggle(
                    value,
                    isOn: Binding(
                        get: { selection.wrappedValue.contains(value) },
                        set: { isSelected in
                            if isSelected {
                                selection.wrappedValue.insert(value)
                            } else {
                                selection.wrappedValue.remove(value)
                            }
                        }
                    )
                )
            }
        }
    }

    private func capabilityText(_ notice: BrowserWebExtensionCapabilityNotice) -> String {
        switch notice {
        case .browserOnlyNoDesktopBridge:
            String(
                localized: "browser.extensions.review.browserOnly",
                defaultValue: "This portable package runs without its desktop app connection."
            )
        case .nativeAppIntegrationUnavailable:
            String(
                localized: "browser.extensions.review.nativeUnavailable",
                defaultValue: "This package cannot communicate with its native desktop app."
            )
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
                        isInstalled: BrowserExtensionsManagerPage.isInstalled(
                            managementID: item.entry.installedManagementID,
                            in: snapshot
                        ),
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
        BrowserWebExtensionPresentationItem,
        Bool
    ) -> Void
    let setEnabled: @MainActor (BrowserWebExtensionPresentationItem, Bool) -> Void
    let revokeOptionalPermissions: @MainActor (BrowserWebExtensionPresentationItem) -> Void
    let prepareUpdate: @MainActor (BrowserWebExtensionPresentationItem) -> Void
    let requestRemoval: @MainActor (BrowserWebExtensionPresentationItem) -> Void

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
                                detail: installedDetail(for: item),
                                iconData: item.iconData,
                                fallbackIcon: item.loadFailure == nil
                                    ? "puzzlepiece.extension"
                                    : "exclamationmark.triangle.fill",
                                fallbackColor: item.loadFailure == nil ? .secondary : .orange,
                                setToolbarPinned: setToolbarPinned,
                                setEnabled: setEnabled,
                                revokeOptionalPermissions: revokeOptionalPermissions,
                                prepareUpdate: prepareUpdate,
                                requestRemoval: requestRemoval
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
                                setToolbarPinned: { _, _ in },
                                setEnabled: { _, _ in },
                                revokeOptionalPermissions: { _ in },
                                prepareUpdate: { _ in },
                                requestRemoval: { _ in }
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
                case .upToDate:
                    Label(
                        String(
                            localized: "browser.extensions.management.upToDate",
                            defaultValue: "This extension is up to date."
                        ),
                        systemImage: "checkmark.circle"
                    )
                    .foregroundStyle(.secondary)
                case .failed(let message):
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
            }

            Text(String(
                localized: "browser.extensions.install.trust",
                defaultValue: "Only add extensions you trust. Installing grants required manifest access; optional access is requested separately."
            ))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func installedDetail(for item: BrowserWebExtensionPresentationItem) -> String {
        if let loadFailure = item.loadFailure {
            return loadFailure
        }
        let enabled = item.isEnabled
            ? String(localized: "browser.extensions.enabled", defaultValue: "Enabled")
            : String(localized: "browser.extensions.disabled", defaultValue: "Disabled")
        guard item.hasTrustedUpdateSource else { return enabled }
        let update = item.canUpdate
            ? String(localized: "browser.extensions.update.available", defaultValue: "Update available")
            : String(localized: "browser.extensions.update.upToDate", defaultValue: "Up to date")
        return String.localizedStringWithFormat(
            String(
                localized: "browser.extensions.update.statusFormat",
                defaultValue: "%1$@, %2$@"
            ),
            enabled,
            update
        )
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
    let item: BrowserWebExtensionPresentationItem?
    var fallbackName = ""
    let detail: String
    let iconData: Data?
    let fallbackIcon: String
    let fallbackColor: Color
    let setToolbarPinned: @MainActor (
        BrowserWebExtensionPresentationItem,
        Bool
    ) -> Void
    let setEnabled: @MainActor (BrowserWebExtensionPresentationItem, Bool) -> Void
    let revokeOptionalPermissions: @MainActor (BrowserWebExtensionPresentationItem) -> Void
    let prepareUpdate: @MainActor (BrowserWebExtensionPresentationItem) -> Void
    let requestRemoval: @MainActor (BrowserWebExtensionPresentationItem) -> Void

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
            if let item, item.managementID != nil {
                Menu {
                    if item.loadFailure != nil {
                        Button(String(
                            localized: "browser.extensions.action.retry",
                            defaultValue: "Retry"
                        )) {
                            setEnabled(item, true)
                        }
                        Button(String(
                            localized: "browser.extensions.disable",
                            defaultValue: "Disable"
                        )) {
                            setEnabled(item, false)
                        }
                    } else {
                        Button(item.isEnabled
                            ? String(localized: "browser.extensions.disable", defaultValue: "Disable")
                            : String(localized: "browser.extensions.enable", defaultValue: "Enable")) {
                            setEnabled(item, !item.isEnabled)
                        }
                    }
                    Button(String(
                        localized: "browser.extensions.permissions.revokeOptional",
                        defaultValue: "Revoke Optional Access"
                    )) {
                        revokeOptionalPermissions(item)
                    }
                    if item.canUpdate {
                        Button(String(
                            localized: "browser.extensions.update.check",
                            defaultValue: "Review Update"
                        )) {
                            prepareUpdate(item)
                        }
                    }
                    Divider()
                    Button(
                        String(localized: "browser.extensions.remove.action", defaultValue: "Remove"),
                        role: .destructive
                    ) {
                        requestRemoval(item)
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .accessibilityIdentifier("BrowserExtensionManage-\(item.id)")
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
                        defaultValue: "Use Add Extension to choose a signed Safari app, extension bundle, or unpacked folder."
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
                                        if item.actionFailure == .popupTimedOut {
                                            Label(
                                                String(
                                                    localized: "browser.extensions.action.retry",
                                                    defaultValue: "Retry"
                                                ),
                                                systemImage: "exclamationmark.triangle.fill"
                                            )
                                            .font(.caption)
                                            .foregroundStyle(.orange)
                                        } else if item.actionFailure == .actionUnavailable {
                                            Label(
                                                String(
                                                    localized: "browser.extensions.action.unavailable",
                                                    defaultValue: "Unavailable"
                                                ),
                                                systemImage: "exclamationmark.triangle.fill"
                                            )
                                            .font(.caption)
                                            .foregroundStyle(.red)
                                        } else if item.actionFailure == .toolbarPinFailed {
                                            Label(
                                                String(
                                                    localized: "browser.extensions.toolbar.pinFailed.short",
                                                    defaultValue: "Pin not saved"
                                                ),
                                                systemImage: "exclamationmark.triangle.fill"
                                            )
                                            .font(.caption)
                                            .foregroundStyle(.red)
                                        }
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
    let item: BrowserWebExtensionPresentationItem
    let setToolbarPinned: @MainActor (
        BrowserWebExtensionPresentationItem,
        Bool
    ) -> Void

    var body: some View {
        Button {
            setToolbarPinned(item, !item.isToolbarPinned)
        } label: {
            Image(systemName: item.actionFailure == .toolbarPinFailed
                ? "exclamationmark.triangle.fill"
                : (item.isToolbarPinned ? "pin.fill" : "pin"))
                .foregroundStyle(item.actionFailure == .toolbarPinFailed
                    ? Color.red
                    : Color.primary)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .safeHelp(helpText)
        .accessibilityLabel(helpText)
        .accessibilityIdentifier("BrowserExtensionToolbarPin-\(item.id)")
    }

    private var helpText: String {
        if item.actionFailure == .toolbarPinFailed {
            return String(
                localized: "browser.extensions.toolbar.pinFailed",
                defaultValue: "The toolbar pin could not be saved. Try again."
            )
        }
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

enum BrowserExtensionIconMetrics {
    static let maximumToolbarArtworkSize: CGFloat = 18

    static func toolbarContentSize(iconPointSize: CGFloat) -> CGFloat {
        min(maximumToolbarArtworkSize, max(1, iconPointSize + 2))
    }
}

enum BrowserExtensionPopoverMetrics {
    static let managerArrowEdge: Edge = .top
}

private struct BrowserExtensionIcon: View {
    let data: Data?
    let fallbackSystemName: String
    let fallbackColor: Color
    var size: CGFloat = 20

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
                    .font(.system(size: size, weight: .medium))
                    .foregroundStyle(fallbackColor)
            }
        }
        .frame(width: size, height: size)
        .clipped()
        .accessibilityHidden(true)
    }
}
