import CMUXExtensionClient
import CmuxExtensionKit
import ExtensionFoundation
import Observation
import SwiftUI

private struct CMUXSidebarExtensionGrant: Codable, Equatable {
    var manifestID: String
    var manifestDisplayName: String
    var apiVersion: CMUXExtensionAPIVersion
    var readScopes: Set<CMUXExtensionScope>
    var actionScopes: Set<CMUXExtensionActionScope>
}

private struct CMUXSidebarExtensionEffectiveGrant: Equatable {
    var manifest: CMUXExtensionManifest
    var readScopes: Set<CMUXExtensionScope>
    var actionScopes: Set<CMUXExtensionActionScope>

    var needsAdditionalApproval: Bool {
        !readScopes.isSuperset(of: manifest.requestedScopes) ||
            !actionScopes.isSuperset(of: manifest.requestedActionScopes)
    }
}

private struct CMUXSidebarExtensionGrantStore {
    static let defaultReadScopes: Set<CMUXExtensionScope> = [.workspaceMetadata]
    static let defaultActionScopes: Set<CMUXExtensionActionScope> = [.selectWorkspace]

    private static let defaultsKey = "cmuxExtensionSidebar.grants.v1"

    var defaults: UserDefaults = .standard

    func effectiveGrant(
        bundleIdentifier: String,
        manifest: CMUXExtensionManifest
    ) -> CMUXSidebarExtensionEffectiveGrant {
        let requestedReadScopes = Set(manifest.requestedScopes)
        let requestedActionScopes = Set(manifest.requestedActionScopes)
        guard let grant = storedGrants()[bundleIdentifier],
              grant.manifestID == manifest.id,
              grant.apiVersion == manifest.minimumAPIVersion else {
            return CMUXSidebarExtensionEffectiveGrant(
                manifest: manifest,
                readScopes: requestedReadScopes.intersection(Self.defaultReadScopes),
                actionScopes: requestedActionScopes.intersection(Self.defaultActionScopes)
            )
        }
        return CMUXSidebarExtensionEffectiveGrant(
            manifest: manifest,
            readScopes: requestedReadScopes.intersection(grant.readScopes),
            actionScopes: requestedActionScopes.intersection(grant.actionScopes)
        )
    }

    func grantRequestedAccess(bundleIdentifier: String, manifest: CMUXExtensionManifest) {
        updateGrant(
            bundleIdentifier: bundleIdentifier,
            manifest: manifest,
            readScopes: Set(manifest.requestedScopes),
            actionScopes: Set(manifest.requestedActionScopes)
        )
    }

    func revokeSensitiveAccess(bundleIdentifier: String, manifest: CMUXExtensionManifest) {
        updateGrant(
            bundleIdentifier: bundleIdentifier,
            manifest: manifest,
            readScopes: Set(manifest.requestedScopes).intersection(Self.defaultReadScopes),
            actionScopes: Set(manifest.requestedActionScopes).intersection(Self.defaultActionScopes)
        )
    }

    private func updateGrant(
        bundleIdentifier: String,
        manifest: CMUXExtensionManifest,
        readScopes: Set<CMUXExtensionScope>,
        actionScopes: Set<CMUXExtensionActionScope>
    ) {
        var grants = storedGrants()
        grants[bundleIdentifier] = CMUXSidebarExtensionGrant(
            manifestID: manifest.id,
            manifestDisplayName: manifest.displayName,
            apiVersion: manifest.minimumAPIVersion,
            readScopes: readScopes,
            actionScopes: actionScopes
        )
        save(grants)
    }

    private func storedGrants() -> [String: CMUXSidebarExtensionGrant] {
        guard let data = defaults.data(forKey: Self.defaultsKey) else { return [:] }
        return (try? JSONDecoder().decode([String: CMUXSidebarExtensionGrant].self, from: data)) ?? [:]
    }

    private func save(_ grants: [String: CMUXSidebarExtensionGrant]) {
        if let data = try? JSONEncoder().encode(grants) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }
}

struct CMUXInstalledExtensionSidebarHostView: View {
    private static let selectedExtensionBundleIDDefaultsKey = "cmuxExtensionSidebar.selectedExtensionBundleId"

    var snapshotProvider: @MainActor () -> CMUXSidebarSnapshot
    var actionHandler: @MainActor (CMUXSidebarAction) -> CMUXExtensionActionResult
    var onUseDefaultSidebar: @MainActor () -> Void = {}

    @State private var identity: AppExtensionIdentity?
    @State private var enabledIdentities: [AppExtensionIdentity] = []
    @State private var selectedExtensionBundleID = UserDefaults.standard.string(
        forKey: Self.selectedExtensionBundleIDDefaultsKey
    )
    @State private var isLoading = true
    @State private var errorText: String?
    @State private var disabledExtensionCount = 0
    @State private var unapprovedExtensionCount = 0
    @State private var browserAnchorView: NSView?
    @State private var xpcHost = CMUXSidebarExtensionHostXPC()
    @State private var effectiveGrant: CMUXSidebarExtensionEffectiveGrant?

    var body: some View {
        Group {
            if let identity {
                VStack(alignment: .leading, spacing: 0) {
                    if let effectiveGrant, effectiveGrant.needsAdditionalApproval {
                        extensionAccessBanner(identity: identity, effectiveGrant: effectiveGrant)
                    }
                    CMUXSidebarExtensionHostView(
                        identity: identity,
                        onConnection: { connection in
                            xpcHost.attach(
                                connection: connection,
                                bundleIdentifier: identity.bundleIdentifier,
                                snapshotProvider: snapshotProvider,
                                actionHandler: actionHandler,
                                onGrantChanged: { grant in
                                    effectiveGrant = grant
                                }
                            )
                        },
                        onDeactivation: { error in
                            xpcHost.invalidate()
                            effectiveGrant = nil
                            if self.identity?.bundleIdentifier == identity.bundleIdentifier {
                                self.identity = nil
                            }
                            errorText = error?.localizedDescription
                        }
                    )
                        .id(identity.bundleIdentifier)
                        .accessibilityIdentifier("CMUXExtensionSidebarHostView")
                        .padding(.top, effectiveGrant?.needsAdditionalApproval == true ? 8 : SidebarWorkspaceScrollInsets.workspaceList.top)
                }
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    if isLoading {
                        ProgressView()
                            .controlSize(.small)
                        Text(String(localized: "sidebar.extensions.loading", defaultValue: "Loading sidebar extensions"))
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    } else {
                        Image(systemName: "puzzlepiece.extension")
                            .font(.system(size: 22, weight: .regular))
                            .foregroundStyle(.secondary)
                        Text(String(localized: "sidebar.extensions.empty.title", defaultValue: "No sidebar extension enabled"))
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.primary)
                        Text(errorText ?? String(
                            localized: "sidebar.extensions.empty.detail",
                            defaultValue: "Install and enable a CMUX sidebar extension to show it here."
                        ))
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if disabledExtensionCount > 0 || unapprovedExtensionCount > 0 {
                            Text(extensionAvailabilityDetail)
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if enabledIdentities.count > 1 {
                            enabledExtensionPicker
                        }
                        Button {
                            if let browserAnchorView {
                                CMUXSidebarExtensionBrowserPresenter.present(
                                    from: browserAnchorView,
                                    title: String(
                                        localized: "sidebar.extensions.browser.title",
                                        defaultValue: "Sidebar Extensions"
                                    )
                                )
                            }
                        } label: {
                            Label(
                                String(localized: "sidebar.extensions.manage", defaultValue: "Manage Sidebar Extensions..."),
                                systemImage: "puzzlepiece.extension"
                            )
                        }
                        .controlSize(.small)
                        Button {
                            onUseDefaultSidebar()
                        } label: {
                            Label(
                                String(localized: "sidebar.extensions.useDefault", defaultValue: "Use Workspace Sidebar"),
                                systemImage: "sidebar.left"
                            )
                        }
                        .controlSize(.small)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, SidebarWorkspaceScrollInsets.workspaceList.top + 12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(TitlebarControlAnchorView { browserAnchorView = $0 })
                .accessibilityIdentifier("CMUXExtensionSidebarEmptyState")
            }
        }
        .task {
            xpcHost.update(snapshotProvider: snapshotProvider, actionHandler: actionHandler)
            await observeExtensionAvailability()
        }
        .onChange(of: snapshotProvider().sequence) { _, _ in
            xpcHost.sendSnapshotDidChange()
        }
    }

    private func observeExtensionAvailability() async {
        isLoading = true
        errorText = nil
        do {
            try await observeEnabledExtensionIdentities(
                extensionPointIdentifier: CMUXSidebarExtensionPoint.identifier,
                staticExtensionPointIdentifier: CMUXSidebarExtensionPoint.staticIdentifier
            )
        } catch {
            identity = nil
            xpcHost.invalidate()
            isLoading = false
            errorText = String(
                localized: "sidebar.extensions.error",
                defaultValue: "CMUX could not load sidebar extensions."
            )
        }
    }

    private var extensionAvailabilityDetail: String {
        if unapprovedExtensionCount > 0 {
            return String(
                localized: "sidebar.extensions.unapproved.detail",
                defaultValue: "An installed sidebar extension needs approval before CMUX can use it."
            )
        }
        return String(
            localized: "sidebar.extensions.disabled.detail",
            defaultValue: "A sidebar extension is installed but disabled."
        )
    }

    private var enabledExtensionPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(String(
                localized: "sidebar.extensions.choose.detail",
                defaultValue: "Choose which enabled extension should replace the sidebar."
            ))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(enabledIdentities, id: \.bundleIdentifier) { enabledIdentity in
                Button {
                    selectExtension(enabledIdentity)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: enabledIdentity.bundleIdentifier == selectedExtensionBundleID ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 11, weight: .medium))
                        Text(enabledIdentity.localizedName)
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func extensionAccessBanner(
        identity: AppExtensionIdentity,
        effectiveGrant: CMUXSidebarExtensionEffectiveGrant
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "sidebar.extensions.access.title", defaultValue: "Limited extension access"))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.primary)
            Text(String.localizedStringWithFormat(
                String(localized: "sidebar.extensions.access.detail", defaultValue: "%@ is using metadata-only access until you grant its requested data and actions."),
                effectiveGrant.manifest.displayName
            ))
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button {
                    xpcHost.grantRequestedAccess(bundleIdentifier: identity.bundleIdentifier)
                    self.effectiveGrant = xpcHost.currentEffectiveGrant
                    xpcHost.sendSnapshotDidChange()
                } label: {
                    Text(String(localized: "sidebar.extensions.access.grant", defaultValue: "Grant Requested Access"))
                }
                .controlSize(.small)
                Button {
                    xpcHost.revokeSensitiveAccess(bundleIdentifier: identity.bundleIdentifier)
                    self.effectiveGrant = xpcHost.currentEffectiveGrant
                    xpcHost.sendSnapshotDidChange()
                } label: {
                    Text(String(localized: "sidebar.extensions.access.keepLimited", defaultValue: "Keep Limited"))
                }
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, SidebarWorkspaceScrollInsets.workspaceList.top + 8)
        .padding(.bottom, 10)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.88))
    }

    private func observeEnabledExtensionIdentities(
        extensionPointIdentifier: String,
        staticExtensionPointIdentifier: StaticString
    ) async throws {
        if #available(macOS 26.0, *) {
            let extensionPoint = try AppExtensionPoint(identifier: staticExtensionPointIdentifier)
            let monitor = try await AppExtensionPoint.Monitor(appExtensionPoint: extensionPoint)
            await observeModernExtensionMonitor(monitor)
            return
        }

        try await observeIdentitySequence(extensionPointIdentifier: extensionPointIdentifier)
    }

    private func observeIdentitySequence(extensionPointIdentifier: String) async throws {
        var identities = try AppExtensionIdentity.matching(appExtensionPointIDs: extensionPointIdentifier)
            .makeAsyncIterator()
        let availabilityTask = Task {
            var availabilityUpdates = AppExtensionIdentity.availabilityUpdates.makeAsyncIterator()
            while !Task.isCancelled {
                guard let availability = await availabilityUpdates.next() else { break }
                disabledExtensionCount = availability.disabledCount
                unapprovedExtensionCount = availability.unapprovedCount
            }
        }
        defer {
            availabilityTask.cancel()
        }
        while !Task.isCancelled {
            guard let update = await identities.next() else { break }
            applyEnabledExtensionIdentities(update)
        }
    }

    private func applyEnabledExtensionIdentities(_ identities: [AppExtensionIdentity]) {
        let sortedIdentities = identities.sorted { $0.localizedName < $1.localizedName }
        enabledIdentities = sortedIdentities
        let nextIdentity: AppExtensionIdentity?
        if let selectedExtensionBundleID,
           let selectedIdentity = sortedIdentities.first(where: { $0.bundleIdentifier == selectedExtensionBundleID }) {
            nextIdentity = selectedIdentity
        } else if sortedIdentities.count == 1 {
            nextIdentity = sortedIdentities[0]
            selectedExtensionBundleID = nextIdentity?.bundleIdentifier
            UserDefaults.standard.set(nextIdentity?.bundleIdentifier, forKey: Self.selectedExtensionBundleIDDefaultsKey)
        } else {
            nextIdentity = nil
        }
        if nextIdentity?.bundleIdentifier != identity?.bundleIdentifier {
            xpcHost.invalidate()
            effectiveGrant = nil
            identity = nextIdentity
        }
        isLoading = false
        errorText = nil
    }

    private func selectExtension(_ selectedIdentity: AppExtensionIdentity) {
        selectedExtensionBundleID = selectedIdentity.bundleIdentifier
        UserDefaults.standard.set(selectedIdentity.bundleIdentifier, forKey: Self.selectedExtensionBundleIDDefaultsKey)
        applyEnabledExtensionIdentities(enabledIdentities)
    }

    @available(macOS 26.0, *)
    private func applyModernExtensionState(_ state: AppExtensionPoint.Monitor.State) {
        disabledExtensionCount = state.disabledCount
        unapprovedExtensionCount = state.unapprovedCount
        let unavailableCount = state.disabledCount + state.unapprovedCount
        let enabledIdentities = unavailableCount >= state.identities.count ? [] : state.identities
        applyEnabledExtensionIdentities(enabledIdentities)
    }

    @available(macOS 26.0, *)
    private func observeModernExtensionMonitor(_ monitor: AppExtensionPoint.Monitor) async {
        while !Task.isCancelled {
            let continuationBox = MonitorContinuationBox()
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    continuationBox.set(continuation)
                    withObservationTracking {
                        applyModernExtensionState(monitor.state)
                    } onChange: {
                        continuationBox.resume()
                    }
                }
            } onCancel: {
                continuationBox.cancel()
            }
            if Task.isCancelled {
                break
            }
        }
    }
}

private final class MonitorContinuationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var isCancelled = false

    func set(_ continuation: CheckedContinuation<Void, Never>) {
        lock.lock()
        if isCancelled {
            lock.unlock()
            continuation.resume()
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func resume() {
        lock.lock()
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume()
    }

    func cancel() {
        lock.lock()
        isCancelled = true
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume()
    }
}

@MainActor
private final class CMUXSidebarExtensionHostXPC {
    private static let fallbackScopes: Set<CMUXExtensionScope> = [.workspaceMetadata]
    private static let fallbackActionScopes: Set<CMUXExtensionActionScope> = [.selectWorkspace]

    private var connection: NSXPCConnection?
    private var extensionProxy: CMUXSidebarExtensionXPC?
    private var exportedObject: CMUXSidebarHostXPCObject?
    private var snapshotProvider: (() -> CMUXSidebarSnapshot)?
    private var actionHandler: ((CMUXSidebarAction) -> CMUXExtensionActionResult)?
    private var allowedScopes = fallbackScopes
    private var allowedActionScopes = fallbackActionScopes
    private var connectionGeneration: UInt64 = 0
    private var bundleIdentifier: String?
    private var currentManifest: CMUXExtensionManifest?
    private var onGrantChanged: ((CMUXSidebarExtensionEffectiveGrant?) -> Void)?
    private let grantStore = CMUXSidebarExtensionGrantStore()

    var currentEffectiveGrant: CMUXSidebarExtensionEffectiveGrant? {
        guard let bundleIdentifier, let currentManifest else { return nil }
        return grantStore.effectiveGrant(bundleIdentifier: bundleIdentifier, manifest: currentManifest)
    }

    func update(
        snapshotProvider: @escaping @MainActor () -> CMUXSidebarSnapshot,
        actionHandler: @escaping @MainActor (CMUXSidebarAction) -> CMUXExtensionActionResult
    ) {
        self.snapshotProvider = snapshotProvider
        self.actionHandler = actionHandler
        exportedObject?.actionHandler = actionHandler
        updateExportedSnapshotFilter()
    }

    func attach(
        connection: NSXPCConnection,
        bundleIdentifier: String,
        snapshotProvider: @escaping @MainActor () -> CMUXSidebarSnapshot,
        actionHandler: @escaping @MainActor (CMUXSidebarAction) -> CMUXExtensionActionResult,
        onGrantChanged: @escaping @MainActor (CMUXSidebarExtensionEffectiveGrant?) -> Void
    ) {
        invalidate()
        connectionGeneration += 1
        let generation = connectionGeneration
        let exportedObject = CMUXSidebarHostXPCObject(
            snapshotProvider: { snapshotProvider().filtered(for: Self.fallbackScopes) },
            actionHandler: { [weak self] action in
                guard let self, self.allowedActionScopes.contains(action.requiredScope) else {
                    return CMUXExtensionActionResult(
                        accepted: false,
                        message: String(localized: "sidebar.extensions.action.scopeRejected", defaultValue: "Extension action is not granted")
                    )
                }
                return actionHandler(action)
            },
            isCurrentGeneration: { [weak self] in
                self?.connectionGeneration == generation
            }
        )
        connection.exportedInterface = NSXPCInterface(with: CMUXSidebarHostXPC.self)
        connection.exportedObject = exportedObject
        connection.remoteObjectInterface = NSXPCInterface(with: CMUXSidebarExtensionXPC.self)
        connection.invalidationHandler = { [weak self, generation] in
            Task { @MainActor in
                self?.clearConnection(ifCurrentGeneration: generation)
            }
        }
        connection.interruptionHandler = { [weak self, generation] in
            Task { @MainActor in
                self?.clearProxy(ifCurrentGeneration: generation)
            }
        }
        self.exportedObject = exportedObject
        self.snapshotProvider = snapshotProvider
        self.actionHandler = actionHandler
        self.connection = connection
        self.bundleIdentifier = bundleIdentifier
        self.currentManifest = nil
        self.onGrantChanged = onGrantChanged
        self.allowedScopes = Self.fallbackScopes
        self.allowedActionScopes = Self.fallbackActionScopes
        self.extensionProxy = connection.remoteObjectProxy as? CMUXSidebarExtensionXPC
        connection.resume()
        requestManifestThenSendInitialSnapshot(generation: generation)
    }

    func sendSnapshotDidChange() {
        guard let extensionProxy, let snapshotProvider else { return }
        do {
            extensionProxy.sidebarSnapshotDidChange(try CMUXSidebarXPCCodec.encodeSnapshot(filteredSnapshot(from: snapshotProvider)))
        } catch {
#if DEBUG
            cmuxDebugLog("extension.sidebar.xpc.snapshot.encode.failed error=\(error.localizedDescription)")
#endif
        }
    }

    func invalidate() {
        connectionGeneration += 1
        let generation = connectionGeneration
        connection?.invalidate()
        clearConnection(ifCurrentGeneration: generation)
    }

    private func clearProxy(ifCurrentGeneration generation: UInt64) {
        guard connectionGeneration == generation else { return }
        extensionProxy = nil
    }

    private func clearConnection(ifCurrentGeneration generation: UInt64) {
        guard connectionGeneration == generation else { return }
        connection = nil
        extensionProxy = nil
        exportedObject = nil
        allowedScopes = Self.fallbackScopes
        allowedActionScopes = Self.fallbackActionScopes
        bundleIdentifier = nil
        currentManifest = nil
        onGrantChanged?(nil)
        onGrantChanged = nil
    }

    private func requestManifestThenSendInitialSnapshot(generation: UInt64) {
        guard let extensionProxy,
              let requestExtensionManifest = extensionProxy.requestExtensionManifest else {
            updateExportedSnapshotFilter()
            sendSnapshotDidChange()
            return
        }
        requestExtensionManifest { [weak self] payload, error in
            Task { @MainActor [generation] in
                guard let self else { return }
                guard self.connectionGeneration == generation else { return }
                if let payload {
                    do {
                        let manifest = try CMUXSidebarXPCCodec.decodeManifest(payload)
                        try CMUXExtensionValidator.validateSidebarManifest(manifest)
                        self.applyManifest(manifest)
                    } catch {
                        self.allowedScopes = Self.fallbackScopes
                        self.allowedActionScopes = Self.fallbackActionScopes
                        self.currentManifest = nil
                        self.onGrantChanged?(nil)
#if DEBUG
                        cmuxDebugLog("extension.sidebar.manifest.invalid error=\(error.localizedDescription)")
#endif
                    }
                } else {
                    self.allowedScopes = Self.fallbackScopes
                    self.allowedActionScopes = Self.fallbackActionScopes
                    self.currentManifest = nil
                    self.onGrantChanged?(nil)
                    if let error {
#if DEBUG
                        cmuxDebugLog("extension.sidebar.manifest.failed error=\(error)")
#endif
                    }
                }
                self.updateExportedSnapshotFilter()
                self.sendSnapshotDidChange()
            }
        }
    }

    func grantRequestedAccess(bundleIdentifier: String) {
        guard self.bundleIdentifier == bundleIdentifier, let currentManifest else { return }
        grantStore.grantRequestedAccess(bundleIdentifier: bundleIdentifier, manifest: currentManifest)
        applyManifest(currentManifest)
    }

    func revokeSensitiveAccess(bundleIdentifier: String) {
        guard self.bundleIdentifier == bundleIdentifier, let currentManifest else { return }
        grantStore.revokeSensitiveAccess(bundleIdentifier: bundleIdentifier, manifest: currentManifest)
        applyManifest(currentManifest)
    }

    private func applyManifest(_ manifest: CMUXExtensionManifest) {
        currentManifest = manifest
        guard let bundleIdentifier else {
            allowedScopes = Self.fallbackScopes
            allowedActionScopes = Self.fallbackActionScopes
            onGrantChanged?(nil)
            return
        }
        let effectiveGrant = grantStore.effectiveGrant(bundleIdentifier: bundleIdentifier, manifest: manifest)
        allowedScopes = effectiveGrant.readScopes
        allowedActionScopes = effectiveGrant.actionScopes
        onGrantChanged?(effectiveGrant)
    }

    private func filteredSnapshot(from snapshotProvider: () -> CMUXSidebarSnapshot) -> CMUXSidebarSnapshot {
        snapshotProvider().filtered(for: allowedScopes)
    }

    private func updateExportedSnapshotFilter() {
        guard let snapshotProvider else { return }
        exportedObject?.snapshotProvider = { [weak self] in
            guard let self else {
                return snapshotProvider().filtered(for: Self.fallbackScopes)
            }
            return filteredSnapshot(from: snapshotProvider)
        }
    }
}

private final class CMUXSidebarHostXPCObject: NSObject, CMUXSidebarHostXPC {
    @MainActor var snapshotProvider: () -> CMUXSidebarSnapshot
    @MainActor var actionHandler: (CMUXSidebarAction) -> CMUXExtensionActionResult
    @MainActor var isCurrentGeneration: () -> Bool

    @MainActor
    init(
        snapshotProvider: @escaping @MainActor () -> CMUXSidebarSnapshot,
        actionHandler: @escaping @MainActor (CMUXSidebarAction) -> CMUXExtensionActionResult,
        isCurrentGeneration: @escaping @MainActor () -> Bool
    ) {
        self.snapshotProvider = snapshotProvider
        self.actionHandler = actionHandler
        self.isCurrentGeneration = isCurrentGeneration
    }

    func requestSidebarSnapshot(reply: @escaping (NSData?, NSString?) -> Void) {
        Task { @MainActor in
            guard isCurrentGeneration() else {
                reply(nil, String(localized: "sidebar.extensions.action.staleConnection", defaultValue: "Extension connection is no longer active") as NSString)
                return
            }
            do {
                reply(try CMUXSidebarXPCCodec.encodeSnapshot(snapshotProvider()), nil)
            } catch {
                reply(nil, error.localizedDescription as NSString)
            }
        }
    }

    func performSidebarAction(_ payload: NSData, reply: @escaping (NSData?, NSString?) -> Void) {
        Task { @MainActor in
            guard isCurrentGeneration() else {
                reply(nil, String(localized: "sidebar.extensions.action.staleConnection", defaultValue: "Extension connection is no longer active") as NSString)
                return
            }
            do {
                let action = try CMUXSidebarXPCCodec.decodeAction(payload)
                let result = actionHandler(action)
                reply(try CMUXSidebarXPCCodec.encodeActionResult(result), nil)
            } catch {
                reply(nil, error.localizedDescription as NSString)
            }
        }
    }
}
