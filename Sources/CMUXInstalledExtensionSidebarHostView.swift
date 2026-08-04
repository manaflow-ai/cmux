import CmuxFoundation
import CmuxNotifications
@_spi(CmuxHostTransport) import CmuxSidebar
@_spi(CmuxHostTransport) import CmuxExtensionKit
import AppKit
import ExtensionFoundation

private struct CMUXSidebarExtensionGrant: Codable, Equatable {
    var manifestID: String
    var manifestDisplayName: String
    var apiVersion: CmuxExtensionAPIVersion
    var readScopes: Set<CmuxExtensionScope>
    var actionScopes: Set<CmuxExtensionActionScope>
}

private struct CMUXSidebarExtensionEffectiveGrant: Equatable {
    var manifest: CmuxExtensionManifest
    var readScopes: Set<CmuxExtensionScope>
    var actionScopes: Set<CmuxExtensionActionScope>

    var needsAdditionalApproval: Bool {
        !readScopes.isSuperset(of: manifest.readScopes) ||
            !actionScopes.isSuperset(of: manifest.actionScopes)
    }

    var hasSensitiveAccess: Bool {
        readScopes.contains { !CMUXSidebarExtensionGrantStore.defaultReadScopes.contains($0) } ||
            actionScopes.contains { !CMUXSidebarExtensionGrantStore.defaultActionScopes.contains($0) }
    }
}

private struct CMUXSidebarExtensionGrantStore {
    static let defaultReadScopes: Set<CmuxExtensionScope> = []
    static let defaultActionScopes: Set<CmuxExtensionActionScope> = []

    private static let defaultsKey = "cmuxExtensionSidebar.grants.v1"

    var defaults: UserDefaults = .standard

    func effectiveGrant(
        bundleIdentifier: String,
        manifest: CmuxExtensionManifest
    ) -> CMUXSidebarExtensionEffectiveGrant {
        let requestedReadScopes = Set(manifest.readScopes)
        let requestedActionScopes = Set(manifest.actionScopes)
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

    func grantRequestedAccess(bundleIdentifier: String, manifest: CmuxExtensionManifest) {
        updateGrant(
            bundleIdentifier: bundleIdentifier,
            manifest: manifest,
            readScopes: Set(manifest.readScopes),
            actionScopes: Set(manifest.actionScopes)
        )
    }

    func revokeSensitiveAccess(bundleIdentifier: String, manifest: CmuxExtensionManifest) {
        updateGrant(
            bundleIdentifier: bundleIdentifier,
            manifest: manifest,
            readScopes: Set(manifest.readScopes).intersection(Self.defaultReadScopes),
            actionScopes: Set(manifest.actionScopes).intersection(Self.defaultActionScopes)
        )
    }

    private func updateGrant(
        bundleIdentifier: String,
        manifest: CmuxExtensionManifest,
        readScopes: Set<CmuxExtensionScope>,
        actionScopes: Set<CmuxExtensionActionScope>
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

private struct CMUXSidebarExtensionLimitedChoiceStore {
    private static let defaultsKey = "cmuxExtensionSidebar.limitedChoices.v1"

    var defaults: UserDefaults = .standard

    func choices() -> Set<String> {
        Set(defaults.stringArray(forKey: Self.defaultsKey) ?? [])
    }

    func insert(_ key: String) {
        var choices = choices()
        choices.insert(key)
        save(choices)
    }

    func remove(_ key: String) {
        var choices = choices()
        choices.remove(key)
        save(choices)
    }

    private func save(_ choices: Set<String>) {
        defaults.set(choices.sorted(), forKey: Self.defaultsKey)
    }
}

@MainActor
final class CMUXSidebarSnapshotCache {
    private struct CachedUnreadState: Equatable {
        let unreadCount: Int
        let latestNotification: String?

        init(workspace: CmuxSidebarWorkspace) {
            unreadCount = workspace.unreadCount
            latestNotification = workspace.latestNotification
        }

        init(summary: SidebarWorkspaceUnreadSummary) {
            unreadCount = summary.unreadCount
            latestNotification = summary.latestNotificationText
        }

        var isEmpty: Bool {
            unreadCount == 0 && latestNotification == nil
        }
    }

    private(set) var snapshot: CmuxSidebarSnapshot?
    private var workspaceIndexByID: [UUID: Int] = [:]
    private var unreadStateByWorkspaceID: [UUID: CachedUnreadState] = [:]

    func replace(with next: CmuxSidebarSnapshot) -> CmuxSidebarSnapshot {
        guard let current = snapshot else {
            store(next)
            return next
        }
        guard current != next else { return current }
        var contentComparableNext = next
        contentComparableNext.sequence = current.sequence
        guard current != contentComparableNext else { return current }
        var updated = next
        updated.sequence = max(next.sequence, current.sequence &+ 1)
        store(updated)
        return updated
    }

    func applyUnread(_ unread: SidebarUnreadSnapshot) -> CmuxSidebarSnapshot? {
        guard var next = snapshot else { return nil }
        var candidateWorkspaceIDs = Set(unreadStateByWorkspaceID.keys)
        candidateWorkspaceIDs.formUnion(unread.summaryByWorkspaceId.keys)
        var changed = false
        for workspaceID in candidateWorkspaceIDs {
            guard let index = workspaceIndexByID[workspaceID] else { continue }
            let state = CachedUnreadState(summary: unread.summary(forWorkspaceId: workspaceID))
            guard unreadStateByWorkspaceID[workspaceID] != state else { continue }
            next.workspaces[index].unreadCount = state.unreadCount
            next.workspaces[index].latestNotification = state.latestNotification
            if state.isEmpty {
                unreadStateByWorkspaceID[workspaceID] = nil
            } else {
                unreadStateByWorkspaceID[workspaceID] = state
            }
            changed = true
        }
        guard changed else { return nil }
        next.sequence &+= 1
        snapshot = next
        return next
    }

    private func store(_ next: CmuxSidebarSnapshot) {
        snapshot = next
        workspaceIndexByID = Dictionary(
            uniqueKeysWithValues: next.workspaces.enumerated().map { ($1.id, $0) }
        )
        unreadStateByWorkspaceID = Dictionary(
            uniqueKeysWithValues: next.workspaces.compactMap { workspace in
                let state = CachedUnreadState(workspace: workspace)
                return state.isEmpty ? nil : (workspace.id, state)
            }
        )
    }
}


@MainActor
final class CMUXInstalledExtensionSidebarHostController: NSViewController {
    private static let selectedExtensionBundleIDDefaultsKey = "cmuxExtensionSidebar.selectedExtensionBundleId"
    private static let selectedExtensionNameDefaultsKey = "cmuxExtensionSidebar.selectedExtensionName"

    private var snapshotProvider: @MainActor () -> CmuxSidebarSnapshot
    private var snapshotUpdateToken: UInt64
    private var unreadSource: SidebarUnreadModel
    private var actionHandler: @MainActor (CmuxSidebarAction) -> CmuxSidebarActionResult
    private var onUseDefaultSidebar: @MainActor () -> Void
    private var identity: AppExtensionIdentity?
    private var enabledIdentities: [AppExtensionIdentity] = []
    private var selectedExtensionBundleID: String?
    private var isLoading = true
    private var errorText: String?
    private var disabledExtensionCount = 0
    private var unapprovedExtensionCount = 0
    private let xpcHost = CMUXSidebarExtensionHostXPC()
    private var effectiveGrant: CMUXSidebarExtensionEffectiveGrant?
    private var blockedManifestReason: String?
    private var keptLimitedManifestKeys = CMUXSidebarExtensionLimitedChoiceStore().choices()
    private let snapshotCache = CMUXSidebarSnapshotCache()
    private var extensionPresentation: CmuxSidebarPresentation?
    private var extensionHostController: CMUXSidebarExtensionHostView?
    private var extensionHostBundleIdentifier: String?
    private var isMutatingExtensionHost = false
    private var availabilityTask: Task<Void, Never>?
    private var unreadObservation: SidebarUnreadObservation?
    private var detailsPopover: NSPopover?
    private let rootStack = NSStackView()

    init(
        snapshotProvider: @escaping @MainActor () -> CmuxSidebarSnapshot,
        snapshotUpdateToken: UInt64,
        unreadSource: SidebarUnreadModel,
        actionHandler: @escaping @MainActor (CmuxSidebarAction) -> CmuxSidebarActionResult,
        onUseDefaultSidebar: @escaping @MainActor () -> Void
    ) {
        self.snapshotProvider = snapshotProvider
        self.snapshotUpdateToken = snapshotUpdateToken
        self.unreadSource = unreadSource
        self.actionHandler = actionHandler
        self.onUseDefaultSidebar = onUseDefaultSidebar
        self.selectedExtensionBundleID = UserDefaults.standard.string(
            forKey: Self.selectedExtensionBundleIDDefaultsKey
        )
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let root = NSView()
        rootStack.orientation = .vertical
        rootStack.alignment = .leading
        rootStack.distribution = .fill
        rootStack.spacing = 0
        rootStack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(rootStack)
        NSLayoutConstraint.activate([
            rootStack.topAnchor.constraint(equalTo: root.topAnchor),
            rootStack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            rootStack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            rootStack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        view = root

        _ = snapshotCache.replace(with: snapshotProvider())
        refreshXPCCallbacks()
        observeUnreadSource()
        startObservingExtensionAvailability()
        render()
    }

    func update(
        snapshotProvider: @escaping @MainActor () -> CmuxSidebarSnapshot,
        snapshotUpdateToken: UInt64,
        unreadSource: SidebarUnreadModel,
        actionHandler: @escaping @MainActor (CmuxSidebarAction) -> CmuxSidebarActionResult,
        onUseDefaultSidebar: @escaping @MainActor () -> Void
    ) {
        let tokenChanged = self.snapshotUpdateToken != snapshotUpdateToken
        let unreadSourceChanged = self.unreadSource !== unreadSource
        self.snapshotProvider = snapshotProvider
        self.snapshotUpdateToken = snapshotUpdateToken
        self.unreadSource = unreadSource
        self.actionHandler = actionHandler
        self.onUseDefaultSidebar = onUseDefaultSidebar
        refreshXPCCallbacks()
        if unreadSourceChanged {
            observeUnreadSource()
        }
        if tokenChanged {
            let snapshot = snapshotCache.replace(with: snapshotProvider())
            xpcHost.sendSnapshotDidChange(snapshot)
        }
        if isViewLoaded {
            render()
        }
    }

    func teardown() {
        availabilityTask?.cancel()
        availabilityTask = nil
        unreadObservation?.cancel()
        unreadObservation = nil
        detailsPopover?.close()
        detailsPopover = nil
        destroyExtensionHost()
        xpcHost.invalidate()
    }

    private func refreshXPCCallbacks() {
        xpcHost.update(
            snapshotProvider: { [weak self] in
                guard let self else {
                    return CmuxSidebarSnapshot(sequence: 0, selectedWorkspaceID: nil, workspaces: [])
                }
                return snapshotCache.replace(with: snapshotProvider())
            },
            actionHandler: { [weak self] action in
                self?.actionHandler(action) ?? CmuxSidebarActionResult(accepted: false)
            }
        )
    }

    private func observeUnreadSource() {
        unreadObservation?.cancel()
        unreadObservation = unreadSource.observeChanges(owner: self) { owner, unreadSnapshot in
            guard let snapshot = owner.snapshotCache.applyUnread(unreadSnapshot) else { return }
            owner.xpcHost.sendSnapshotDidChange(snapshot)
        }
    }

    private func startObservingExtensionAvailability() {
        availabilityTask?.cancel()
        availabilityTask = Task { @MainActor [weak self] in
            await self?.observeExtensionAvailabilityNative()
        }
    }

    private func observeExtensionAvailabilityNative() async {
        isLoading = true
        errorText = nil
        render()
        do {
            var identities = try AppExtensionIdentity.matching(
                appExtensionPointIDs: CmuxSidebarExtensionPoint.identifier()
            ).makeAsyncIterator()
            let availabilityUpdatesTask = Task { @MainActor [weak self] in
                var updates = AppExtensionIdentity.availabilityUpdates.makeAsyncIterator()
                while !Task.isCancelled, let availability = await updates.next() {
                    guard let self else { return }
                    disabledExtensionCount = availability.disabledCount
                    unapprovedExtensionCount = availability.unapprovedCount
                    render()
                }
            }
            defer { availabilityUpdatesTask.cancel() }
            while !Task.isCancelled, let update = await identities.next() {
                applyEnabledExtensionIdentitiesNative(update)
            }
        } catch {
            identity = nil
            destroyExtensionHost()
            xpcHost.invalidate()
            blockedManifestReason = nil
            isLoading = false
            errorText = String(
                localized: "sidebar.extensions.error",
                defaultValue: "CMUX could not load sidebar extensions."
            )
            render()
        }
    }

    private func applyEnabledExtensionIdentitiesNative(_ identities: [AppExtensionIdentity]) {
        let sortedIdentities = deduplicatedExtensionIdentitiesNative(identities)
        enabledIdentities = sortedIdentities
        let nextIdentity: AppExtensionIdentity?
        if let selectedExtensionBundleID,
           let selected = sortedIdentities.first(where: { $0.bundleIdentifier == selectedExtensionBundleID }) {
            nextIdentity = selected
        } else if selectedExtensionBundleID == nil, sortedIdentities.count == 1 {
            nextIdentity = sortedIdentities[0]
            selectedExtensionBundleID = nextIdentity?.bundleIdentifier
            UserDefaults.standard.set(
                nextIdentity?.bundleIdentifier,
                forKey: Self.selectedExtensionBundleIDDefaultsKey
            )
        } else {
            nextIdentity = nil
        }
        updateSelectedExtensionNameNative(nextIdentity)
        if nextIdentity?.bundleIdentifier != identity?.bundleIdentifier {
            destroyExtensionHost()
            xpcHost.invalidate()
            effectiveGrant = nil
            blockedManifestReason = nil
            extensionPresentation = nil
            identity = nextIdentity
        }
        isLoading = false
        errorText = nil
        render()
    }

    private func deduplicatedExtensionIdentitiesNative(
        _ identities: [AppExtensionIdentity]
    ) -> [AppExtensionIdentity] {
        let sorted = identities.sorted {
            if $0.localizedName == $1.localizedName {
                return $0.bundleIdentifier < $1.bundleIdentifier
            }
            return $0.localizedName < $1.localizedName
        }
        var seen = Set<String>()
        return sorted.filter { seen.insert($0.bundleIdentifier).inserted }
    }

    private func selectExtensionNative(_ selectedIdentity: AppExtensionIdentity) {
        selectedExtensionBundleID = selectedIdentity.bundleIdentifier
        UserDefaults.standard.set(
            selectedIdentity.bundleIdentifier,
            forKey: Self.selectedExtensionBundleIDDefaultsKey
        )
        UserDefaults.standard.set(
            selectedIdentity.localizedName,
            forKey: Self.selectedExtensionNameDefaultsKey
        )
        applyEnabledExtensionIdentitiesNative(enabledIdentities)
    }

    private func updateSelectedExtensionNameNative(_ selectedIdentity: AppExtensionIdentity?) {
        if let selectedIdentity {
            UserDefaults.standard.set(
                selectedIdentity.localizedName,
                forKey: Self.selectedExtensionNameDefaultsKey
            )
        } else if selectedExtensionBundleID == nil {
            UserDefaults.standard.removeObject(forKey: Self.selectedExtensionNameDefaultsKey)
        }
    }

    private func ensureExtensionHost(
        for activeIdentity: AppExtensionIdentity
    ) -> CMUXSidebarExtensionHostView {
        if let extensionHostController,
           extensionHostBundleIdentifier == activeIdentity.bundleIdentifier {
            updateExtensionHost(extensionHostController, identity: activeIdentity)
            return extensionHostController
        }
        destroyExtensionHost()
        let controller = CMUXSidebarExtensionHostView(identity: activeIdentity)
        extensionHostController = controller
        extensionHostBundleIdentifier = activeIdentity.bundleIdentifier
        addChild(controller)
        updateExtensionHost(controller, identity: activeIdentity)
        return controller
    }

    private func updateExtensionHost(
        _ controller: CMUXSidebarExtensionHostView,
        identity activeIdentity: AppExtensionIdentity
    ) {
        controller.update(
            identity: activeIdentity,
            presentation: extensionPresentation,
            onConnection: { [weak self] connection in
                guard let self else { return }
                xpcHost.attach(
                    connection: connection,
                    bundleIdentifier: activeIdentity.bundleIdentifier,
                    snapshotProvider: { [weak self] in
                        guard let self else {
                            return CmuxSidebarSnapshot(sequence: 0, selectedWorkspaceID: nil, workspaces: [])
                        }
                        return snapshotCache.replace(with: snapshotProvider())
                    },
                    actionHandler: { [weak self] action in
                        self?.actionHandler(action) ?? CmuxSidebarActionResult(accepted: false)
                    },
                    onGrantChanged: { [weak self] grant in
                        self?.effectiveGrant = grant
                        self?.render()
                    },
                    onManifestBlocked: { [weak self] reason in
                        self?.blockedManifestReason = reason
                        self?.render()
                    },
                    onPresentationChanged: { [weak self] presentation in
                        self?.extensionPresentation = presentation
                        self?.render()
                    }
                )
            },
            onDeactivation: { [weak self] error in
                guard let self else { return }
                xpcHost.invalidate()
                extensionPresentation = nil
                effectiveGrant = nil
                if identity?.bundleIdentifier == activeIdentity.bundleIdentifier {
                    blockedManifestReason = "connectionInterrupted"
                }
                errorText = error?.localizedDescription
                render()
            },
            onTeardown: { [weak self] in
                self?.xpcHost.invalidate()
                self?.extensionPresentation = nil
            },
            onPresentationAction: { [weak self] actionID in
                self?.xpcHost.performPresentationAction(actionID)
            }
        )
    }

    private func destroyExtensionHost() {
        guard !isMutatingExtensionHost else { return }
        isMutatingExtensionHost = true
        defer { isMutatingExtensionHost = false }
        let controller = extensionHostController
        extensionHostController = nil
        extensionHostBundleIdentifier = nil
        controller?.teardown()
        controller?.view.removeFromSuperview()
        controller?.removeFromParent()
    }
}

private extension CMUXInstalledExtensionSidebarHostController {
    var emptyStateTitleNative: String {
        if enabledIdentities.count > 1 {
            return String(
                localized: "sidebar.extensions.choose.title",
                defaultValue: "Choose a sidebar extension"
            )
        }
        return String(
            localized: "sidebar.extensions.empty.title",
            defaultValue: "No sidebar extension enabled"
        )
    }

    var emptyStateDetailNative: String {
        if enabledIdentities.count > 1 {
            return String(
                localized: "sidebar.extensions.choose.detail",
                defaultValue: "Choose which enabled extension should replace the sidebar."
            )
        }
        return String(
            localized: "sidebar.extensions.empty.detail",
            defaultValue: "Install and enable a CMUX sidebar extension to show it here."
        )
    }

    var extensionAvailabilityDetailNative: String {
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

    func render() {
        guard isViewLoaded, !isMutatingExtensionHost else { return }
        for arrangedSubview in rootStack.arrangedSubviews {
            rootStack.removeArrangedSubview(arrangedSubview)
            arrangedSubview.removeFromSuperview()
        }
        if let identity {
            addFullWidthArrangedSubview(makeControlStrip(activeIdentity: identity))
            if let effectiveGrant,
               shouldShowAccessBannerNative(identity: identity, effectiveGrant: effectiveGrant) {
                addFullWidthArrangedSubview(
                    makeAccessBanner(identity: identity, effectiveGrant: effectiveGrant)
                )
            }
            let extensionHost = ensureExtensionHost(for: identity)
            if let blockedManifestReason {
                addFillingArrangedSubview(makeBlockedView(reason: blockedManifestReason))
            } else {
                addFillingArrangedSubview(extensionHost.view)
            }
        } else if isLoading {
            addFillingArrangedSubview(makeLoadingView())
        } else {
            addFillingArrangedSubview(makeEmptyView())
        }
    }

    func addFullWidthArrangedSubview(_ child: NSView) {
        child.translatesAutoresizingMaskIntoConstraints = false
        rootStack.addArrangedSubview(child)
        child.widthAnchor.constraint(equalTo: rootStack.widthAnchor).isActive = true
    }

    func addFillingArrangedSubview(_ child: NSView) {
        child.setContentHuggingPriority(.defaultLow, for: .vertical)
        child.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        addFullWidthArrangedSubview(child)
    }

    func makeControlStrip(activeIdentity: AppExtensionIdentity) -> NSView {
        let background = NSVisualEffectView()
        background.material = .sidebar
        background.blendingMode = .withinWindow
        background.state = .active

        let controls = NSStackView()
        controls.orientation = .horizontal
        controls.alignment = .centerY
        controls.spacing = 8
        controls.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(controls)
        NSLayoutConstraint.activate([
            controls.topAnchor.constraint(
                equalTo: background.topAnchor,
                constant: SidebarWorkspaceScrollInsets.workspaceList.top + 8
            ),
            controls.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 12),
            controls.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -12),
            controls.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -8),
        ])

        if enabledIdentities.count > 1 {
            controls.addArrangedSubview(makeExtensionPicker(activeIdentity: activeIdentity))
        } else {
            let provider = NSStackView(views: [
                makeSymbolView("puzzlepiece.extension", pointSize: 12, weight: .semibold),
                makeLabel(
                    activeIdentity.localizedName,
                    size: 12,
                    weight: .semibold,
                    color: .secondaryLabelColor
                ),
            ])
            provider.orientation = .horizontal
            provider.alignment = .centerY
            provider.spacing = 5
            provider.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            controls.addArrangedSubview(provider)
        }

        let spring = NSView()
        spring.setContentHuggingPriority(.defaultLow, for: .horizontal)
        controls.addArrangedSubview(spring)
        if effectiveGrant?.needsAdditionalApproval == true {
            let limited = makeButton(
                title: String(
                    localized: "sidebar.extensions.access.statusLimited",
                    defaultValue: "Limited"
                ),
                symbol: "lock",
                action: #selector(reviewAccessNative(_:))
            )
            limited.controlSize = .mini
            limited.toolTip = String(
                localized: "sidebar.extensions.access.statusLimited.help",
                defaultValue: "This extension has limited access."
            )
            controls.addArrangedSubview(limited)
        }
        let details = NSButton(
            image: NSImage(systemSymbolName: "info.circle", accessibilityDescription: nil) ?? NSImage(),
            target: self,
            action: #selector(showDetailsNative(_:))
        )
        details.isBordered = false
        details.controlSize = .small
        details.toolTip = String(
            localized: "sidebar.extensions.details.help",
            defaultValue: "Show extension details"
        )
        controls.addArrangedSubview(details)
        return background
    }

    func makeExtensionPicker(activeIdentity: AppExtensionIdentity?) -> NSPopUpButton {
        let picker = NSPopUpButton(frame: .zero, pullsDown: false)
        picker.controlSize = .small
        picker.target = self
        picker.action = #selector(extensionPickerChangedNative(_:))
        for enabledIdentity in enabledIdentities {
            let item = NSMenuItem(
                title: enabledIdentity.localizedName,
                action: nil,
                keyEquivalent: ""
            )
            item.image = NSImage(
                systemSymbolName: "puzzlepiece.extension",
                accessibilityDescription: nil
            )
            item.representedObject = enabledIdentity.bundleIdentifier
            picker.menu?.addItem(item)
        }
        if let bundleIdentifier = activeIdentity?.bundleIdentifier,
           let selectedIndex = enabledIdentities.firstIndex(where: {
               $0.bundleIdentifier == bundleIdentifier
           }) {
            picker.selectItem(at: selectedIndex)
        }
        return picker
    }

    func makeLoadingView() -> NSView {
        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.startAnimation(nil)
        let stack = NSStackView(views: [
            spinner,
            makeLabel(
                String(
                    localized: "sidebar.extensions.loading",
                    defaultValue: "Loading sidebar extensions"
                ),
                size: 12,
                color: .secondaryLabelColor
            ),
        ])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 10
        return makeCenteredContainer(
            stack,
            accessibilityIdentifier: "CMUXExtensionSidebarEmptyState"
        )
    }

    func makeEmptyView() -> NSView {
        let symbolPlate = NSVisualEffectView()
        symbolPlate.material = .contentBackground
        symbolPlate.blendingMode = .withinWindow
        symbolPlate.state = .active
        symbolPlate.wantsLayer = true
        symbolPlate.layer?.cornerRadius = 16
        let symbol = makeSymbolView("puzzlepiece.extension", pointSize: 26)
        symbol.translatesAutoresizingMaskIntoConstraints = false
        symbolPlate.addSubview(symbol)
        NSLayoutConstraint.activate([
            symbolPlate.widthAnchor.constraint(equalToConstant: 60),
            symbolPlate.heightAnchor.constraint(equalToConstant: 60),
            symbol.centerXAnchor.constraint(equalTo: symbolPlate.centerXAnchor),
            symbol.centerYAnchor.constraint(equalTo: symbolPlate.centerYAnchor),
        ])

        let title = makeLabel(
            emptyStateTitleNative,
            size: 14,
            weight: .semibold,
            alignment: .center
        )
        let detail = makeLabel(
            errorText ?? emptyStateDetailNative,
            size: 12,
            color: .secondaryLabelColor,
            alignment: .center,
            wraps: true
        )
        let textStack = NSStackView(views: [title, detail])
        textStack.orientation = .vertical
        textStack.alignment = .centerX
        textStack.spacing = 6
        if disabledExtensionCount > 0 || unapprovedExtensionCount > 0 {
            textStack.addArrangedSubview(makeLabel(
                extensionAvailabilityDetailNative,
                size: 12,
                color: .secondaryLabelColor,
                alignment: .center,
                wraps: true
            ))
        }

        let actions = NSStackView()
        actions.orientation = .horizontal
        actions.alignment = .centerY
        actions.spacing = 8
        if enabledIdentities.count > 1 {
            actions.addArrangedSubview(makeExtensionPicker(activeIdentity: nil))
        }
        actions.addArrangedSubview(makeButton(
            title: String(
                localized: "sidebar.extensions.manage.short",
                defaultValue: "Manage"
            ),
            symbol: "puzzlepiece.extension",
            action: #selector(manageExtensionsNative(_:))
        ))
        actions.addArrangedSubview(makeButton(
            title: String(
                localized: "sidebar.extensions.useDefault.short",
                defaultValue: "Use Default"
            ),
            symbol: "sidebar.left",
            action: #selector(useDefaultSidebarNative(_:))
        ))

        let stack = NSStackView(views: [symbolPlate, textStack, actions])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 16
        return makeCenteredContainer(
            stack,
            accessibilityIdentifier: "CMUXExtensionSidebarEmptyState"
        )
    }

    func makeCenteredContainer(
        _ content: NSView,
        accessibilityIdentifier: String
    ) -> NSView {
        let container = NSView()
        container.setAccessibilityIdentifier(accessibilityIdentifier)
        content.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(content)
        NSLayoutConstraint.activate([
            content.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            content.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            content.leadingAnchor.constraint(
                greaterThanOrEqualTo: container.leadingAnchor,
                constant: 24
            ),
            content.trailingAnchor.constraint(
                lessThanOrEqualTo: container.trailingAnchor,
                constant: -24
            ),
            content.widthAnchor.constraint(lessThanOrEqualToConstant: 320),
        ])
        return container
    }

    func makeAccessBanner(
        identity: AppExtensionIdentity,
        effectiveGrant: CMUXSidebarExtensionEffectiveGrant
    ) -> NSView {
        let background = NSVisualEffectView()
        background.material = .contentBackground
        background.blendingMode = .withinWindow
        background.state = .active
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: background.topAnchor, constant: 8),
            stack.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -12),
            stack.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -10),
        ])
        stack.addArrangedSubview(makeLabel(
            String(
                localized: "sidebar.extensions.access.title",
                defaultValue: "Limited extension access"
            ),
            size: 12,
            weight: .semibold
        ))
        stack.addArrangedSubview(makeLabel(
            String.localizedStringWithFormat(
                String(
                    localized: "sidebar.extensions.access.detail",
                    defaultValue: "%@ will not receive workspace data or run actions until you grant its requested access."
                ),
                effectiveGrant.manifest.displayName
            ),
            size: 11,
            color: .secondaryLabelColor,
            wraps: true
        ))
        for description in pendingPermissionDescriptionsNative(effectiveGrant: effectiveGrant) {
            stack.addArrangedSubview(makeLabel(
                "• \(description)",
                size: 11,
                color: .secondaryLabelColor,
                wraps: true
            ))
        }
        let actions = NSStackView(views: [
            makeButton(
                title: String(
                    localized: "sidebar.extensions.access.review",
                    defaultValue: "Review Access..."
                ),
                action: #selector(reviewAccessNative(_:))
            ),
            makeButton(
                title: String(
                    localized: "sidebar.extensions.access.keepLimited",
                    defaultValue: "Keep Limited"
                ),
                action: #selector(keepLimitedAccessFromControlNative(_:))
            ),
        ])
        actions.orientation = .horizontal
        actions.spacing = 8
        stack.addArrangedSubview(actions)
        return background
    }

    func makeBlockedView(reason: String) -> NSView {
        let container = NSView()
        container.setAccessibilityIdentifier("CMUXExtensionSidebarBlockedState")
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        stack.addArrangedSubview(makeSymbolView(
            "exclamationmark.triangle",
            pointSize: 20
        ))
        stack.addArrangedSubview(makeLabel(
            String(
                localized: "sidebar.extensions.blocked.title",
                defaultValue: "Extension Blocked"
            ),
            size: 13,
            weight: .semibold
        ))
        stack.addArrangedSubview(makeLabel(
            blockedDetailTextNative(reason: reason),
            size: 12,
            color: .secondaryLabelColor,
            wraps: true
        ))
        let actions = NSStackView(views: [
            makeButton(
                title: String(
                    localized: "sidebar.extensions.retry",
                    defaultValue: "Try Again"
                ),
                symbol: "arrow.clockwise",
                action: #selector(retryExtensionNative(_:))
            ),
            makeButton(
                title: String(
                    localized: "sidebar.extensions.useDefault.short",
                    defaultValue: "Use Default"
                ),
                symbol: "sidebar.left",
                action: #selector(useDefaultSidebarNative(_:))
            ),
            makeButton(
                title: String(
                    localized: "sidebar.extensions.manage.short",
                    defaultValue: "Manage"
                ),
                symbol: "puzzlepiece.extension",
                action: #selector(manageExtensionsNative(_:))
            ),
        ])
        actions.orientation = .horizontal
        actions.spacing = 8
        stack.addArrangedSubview(actions)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 14),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(
                lessThanOrEqualTo: container.trailingAnchor,
                constant: -14
            ),
        ])
        return container
    }

    func makeLabel(
        _ text: String,
        size: CGFloat,
        weight: NSFont.Weight = .regular,
        color: NSColor = .labelColor,
        alignment: NSTextAlignment = .left,
        wraps: Bool = false
    ) -> NSTextField {
        let label = wraps
            ? NSTextField(wrappingLabelWithString: text)
            : NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: size, weight: weight)
        label.textColor = color
        label.alignment = alignment
        label.maximumNumberOfLines = wraps ? 0 : 1
        label.lineBreakMode = wraps ? .byWordWrapping : .byTruncatingTail
        return label
    }

    func makeSymbolView(
        _ systemName: String,
        pointSize: CGFloat,
        weight: NSFont.Weight = .regular
    ) -> NSImageView {
        let configuration = NSImage.SymbolConfiguration(
            pointSize: pointSize,
            weight: weight
        )
        let image = NSImage(
            systemSymbolName: systemName,
            accessibilityDescription: nil
        )?.withSymbolConfiguration(configuration) ?? NSImage()
        let imageView = NSImageView(image: image)
        imageView.contentTintColor = .secondaryLabelColor
        return imageView
    }

    func makeButton(
        title: String,
        symbol: String? = nil,
        action: Selector
    ) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        button.controlSize = .small
        if let symbol {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            button.imagePosition = .imageLeading
        }
        return button
    }
}

private extension CMUXInstalledExtensionSidebarHostController {
    @objc func extensionPickerChangedNative(_ sender: NSPopUpButton) {
        guard let bundleIdentifier = sender.selectedItem?.representedObject as? String,
              let selected = enabledIdentities.first(where: {
                  $0.bundleIdentifier == bundleIdentifier
              }) else { return }
        selectExtensionNative(selected)
    }

    @objc func manageExtensionsNative(_ sender: Any?) {
        detailsPopover?.close()
        detailsPopover = nil
        guard let anchorView = view.window?.contentView
            ?? NSApp.keyWindow?.contentView
            ?? NSApp.mainWindow?.contentView else { return }
        AppDelegate.shared?.openSidebarExtensionBrowser(
            from: anchorView,
            title: String(
                localized: "sidebar.extensions.browser.title",
                defaultValue: "Sidebar Extensions"
            )
        )
    }

    @objc func useDefaultSidebarNative(_ sender: Any?) {
        detailsPopover?.close()
        detailsPopover = nil
        onUseDefaultSidebar()
    }

    @objc func retryExtensionNative(_ sender: Any?) {
        blockedManifestReason = nil
        effectiveGrant = nil
        extensionPresentation = nil
        xpcHost.invalidate()
        destroyExtensionHost()
        render()
    }

    @objc func reviewAccessNative(_ sender: Any?) {
        detailsPopover?.close()
        detailsPopover = nil
        guard let identity, let effectiveGrant else { return }
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = String.localizedStringWithFormat(
            String(
                localized: "sidebar.extensions.access.review.title",
                defaultValue: "Review access for %@"
            ),
            effectiveGrant.manifest.displayName
        )
        let configuration = "\(effectiveGrant.manifest.id) · API \(effectiveGrant.manifest.minimumAPIVersion.major).\(effectiveGrant.manifest.minimumAPIVersion.minor)"
        let permissions = pendingPermissionDescriptionsNative(effectiveGrant: effectiveGrant)
            .map { "• \($0)" }
            .joined(separator: "\n")
        alert.informativeText = [
            identity.bundleIdentifier,
            configuration,
            String(
                localized: "sidebar.extensions.access.review.detail",
                defaultValue: "CMUX will only share the following data and actions if you allow this request."
            ),
            permissions,
        ]
        .filter { !$0.isEmpty }
        .joined(separator: "\n\n")
        alert.addButton(withTitle: String(
            localized: "sidebar.extensions.access.allow",
            defaultValue: "Allow Requested Access"
        ))
        alert.addButton(withTitle: String(
            localized: "sidebar.extensions.access.keepLimited",
            defaultValue: "Keep Limited"
        ))
        alert.addButton(withTitle: String(
            localized: "common.cancel",
            defaultValue: "Cancel"
        ))

        let handleResponse: @MainActor (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self else { return }
            if response == .alertFirstButtonReturn {
                grantRequestedAccessNative(identity: identity, effectiveGrant: effectiveGrant)
            } else if response == .alertSecondButtonReturn {
                keepLimitedAccessNative(identity: identity, effectiveGrant: effectiveGrant)
            }
        }
        if let window = view.window {
            alert.beginSheetModal(for: window) { response in
                Task { @MainActor in handleResponse(response) }
            }
        } else {
            handleResponse(alert.runModal())
        }
    }

    @objc func keepLimitedAccessFromControlNative(_ sender: Any?) {
        guard let identity, let effectiveGrant else { return }
        keepLimitedAccessNative(identity: identity, effectiveGrant: effectiveGrant)
    }

    @objc func keepLimitedAccessFromDetailsNative(_ sender: Any?) {
        detailsPopover?.close()
        detailsPopover = nil
        guard let identity, let effectiveGrant else { return }
        keepLimitedAccessNative(identity: identity, effectiveGrant: effectiveGrant)
    }

    @objc func showDetailsNative(_ sender: NSButton) {
        detailsPopover?.close()
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        let contentController = NSViewController()
        contentController.view = makeDetailsViewNative(activeIdentity: identity)
        let permissionCount = (effectiveGrant?.manifest.readScopes.count ?? 0)
            + (effectiveGrant?.manifest.actionScopes.count ?? 0)
        popover.contentSize = NSSize(
            width: 340,
            height: min(680, max(300, 290 + permissionCount * 38))
        )
        popover.contentViewController = contentController
        detailsPopover = popover
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxY)
    }

    func makeDetailsViewNative(activeIdentity: AppExtensionIdentity?) -> NSView {
        let root = NSView()
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 14),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor, constant: -14),
        ])

        let headingText = NSStackView(views: [
            makeLabel(
                activeIdentity?.localizedName ?? String(
                    localized: "sidebar.provider.extensions.title",
                    defaultValue: "Extension Sidebar"
                ),
                size: 13,
                weight: .semibold
            ),
            makeLabel(
                String(
                    localized: "sidebar.extensions.details.runtime",
                    defaultValue: "Secure extension connection"
                ),
                size: 11,
                color: .secondaryLabelColor
            ),
        ])
        headingText.orientation = .vertical
        headingText.alignment = .leading
        headingText.spacing = 2
        let heading = NSStackView(views: [
            makeSymbolView("puzzlepiece.extension", pointSize: 18, weight: .medium),
            headingText,
        ])
        heading.orientation = .horizontal
        heading.alignment = .centerY
        heading.spacing = 8
        stack.addArrangedSubview(heading)

        stack.addArrangedSubview(makeDetailRowNative(
            title: String(
                localized: "sidebar.extensions.details.status",
                defaultValue: "Status"
            ),
            value: blockedManifestReason.map(blockedStatusTextNative(reason:))
                ?? (activeIdentity == nil
                    ? String(
                        localized: "sidebar.extensions.details.statusWaiting",
                        defaultValue: "Waiting for an enabled extension"
                    )
                    : String(
                        localized: "sidebar.extensions.details.statusActive",
                        defaultValue: "Connected"
                    ))
        ))
        if let activeIdentity {
            stack.addArrangedSubview(makeDetailRowNative(
                title: String(
                    localized: "sidebar.extensions.details.bundle",
                    defaultValue: "Bundle"
                ),
                value: activeIdentity.bundleIdentifier
            ))
        }
        if let manifest = effectiveGrant?.manifest {
            stack.addArrangedSubview(makeDetailRowNative(
                title: String(
                    localized: "sidebar.extensions.details.manifest",
                    defaultValue: "Configuration"
                ),
                value: "\(manifest.id) · API \(manifest.minimumAPIVersion.major).\(manifest.minimumAPIVersion.minor)"
            ))
        }

        if let effectiveGrant {
            stack.addArrangedSubview(makeSeparatorNative())
            let permissions = NSStackView()
            permissions.orientation = .vertical
            permissions.alignment = .leading
            permissions.spacing = 8
            permissions.addArrangedSubview(makeLabel(
                String(
                    localized: "sidebar.extensions.details.permissions",
                    defaultValue: "Permissions"
                ),
                size: 12,
                weight: .semibold
            ))
            for scope in effectiveGrant.manifest.readScopes {
                permissions.addArrangedSubview(makePermissionRowNative(
                    title: scope.displayName,
                    detail: permissionDescriptionNative(scope: scope),
                    isGranted: effectiveGrant.readScopes.contains(scope)
                ))
            }
            for scope in effectiveGrant.manifest.actionScopes {
                permissions.addArrangedSubview(makePermissionRowNative(
                    title: scope.displayName,
                    detail: permissionDescriptionNative(actionScope: scope),
                    isGranted: effectiveGrant.actionScopes.contains(scope)
                ))
            }
            stack.addArrangedSubview(permissions)
            permissions.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        } else if let blockedManifestReason {
            stack.addArrangedSubview(makeSeparatorNative())
            stack.addArrangedSubview(makeLabel(
                blockedDetailTextNative(reason: blockedManifestReason),
                size: 11,
                color: .secondaryLabelColor,
                wraps: true
            ))
        }

        stack.addArrangedSubview(makeSeparatorNative())
        if let effectiveGrant {
            let accessActions = NSStackView(views: [
                makeButton(
                    title: String(
                        localized: "sidebar.extensions.access.review",
                        defaultValue: "Review Access..."
                    ),
                    action: #selector(reviewAccessNative(_:))
                ),
                makeButton(
                    title: String(
                        localized: "sidebar.extensions.access.keepLimited",
                        defaultValue: "Keep Limited"
                    ),
                    action: #selector(keepLimitedAccessFromDetailsNative(_:))
                ),
            ])
            accessActions.orientation = .horizontal
            accessActions.spacing = 8
            (accessActions.arrangedSubviews[0] as? NSButton)?.isEnabled =
                effectiveGrant.needsAdditionalApproval
            (accessActions.arrangedSubviews[1] as? NSButton)?.isEnabled =
                effectiveGrant.hasSensitiveAccess
            stack.addArrangedSubview(accessActions)
        }
        let generalActions = NSStackView(views: [
            makeButton(
                title: String(
                    localized: "sidebar.extensions.manage.short",
                    defaultValue: "Manage"
                ),
                action: #selector(manageExtensionsNative(_:))
            ),
            makeButton(
                title: String(
                    localized: "sidebar.extensions.useDefault.short",
                    defaultValue: "Use Default"
                ),
                action: #selector(useDefaultSidebarNative(_:))
            ),
        ])
        generalActions.orientation = .horizontal
        generalActions.spacing = 8
        stack.addArrangedSubview(generalActions)
        return root
    }

    func makeDetailRowNative(title: String, value: String) -> NSView {
        let titleLabel = makeLabel(
            title,
            size: 11,
            weight: .medium,
            color: .secondaryLabelColor
        )
        titleLabel.widthAnchor.constraint(equalToConstant: 64).isActive = true
        let valueLabel = makeLabel(value, size: 11, wraps: true)
        let row = NSStackView(views: [titleLabel, valueLabel])
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.spacing = 8
        return row
    }

    func makePermissionRowNative(
        title: String,
        detail: String,
        isGranted: Bool
    ) -> NSView {
        let text = NSStackView(views: [
            makeLabel(title, size: 11, weight: .medium),
            makeLabel(detail, size: 10, color: .secondaryLabelColor, wraps: true),
        ])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1
        let status = makeLabel(
            isGranted
                ? String(
                    localized: "sidebar.extensions.details.granted",
                    defaultValue: "Granted"
                )
                : String(
                    localized: "sidebar.extensions.details.pending",
                    defaultValue: "Pending"
                ),
            size: 10,
            weight: .medium,
            color: .secondaryLabelColor
        )
        let row = NSStackView(views: [
            makeSymbolView(
                isGranted ? "checkmark.circle.fill" : "circle",
                pointSize: 11,
                weight: .medium
            ),
            text,
            NSView(),
            status,
        ])
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = 6
        if isGranted, let icon = row.arrangedSubviews.first as? NSImageView {
            icon.contentTintColor = .systemGreen
        }
        row.arrangedSubviews[2].setContentHuggingPriority(.defaultLow, for: .horizontal)
        return row
    }

    func makeSeparatorNative() -> NSBox {
        let separator = NSBox()
        separator.boxType = .separator
        return separator
    }

    func shouldShowAccessBannerNative(
        identity: AppExtensionIdentity,
        effectiveGrant: CMUXSidebarExtensionEffectiveGrant
    ) -> Bool {
        effectiveGrant.needsAdditionalApproval
            && !keptLimitedManifestKeys.contains(
                limitedChoiceKeyNative(identity: identity, effectiveGrant: effectiveGrant)
            )
    }

    func grantRequestedAccessNative(
        identity: AppExtensionIdentity,
        effectiveGrant: CMUXSidebarExtensionEffectiveGrant
    ) {
        let key = limitedChoiceKeyNative(identity: identity, effectiveGrant: effectiveGrant)
        keptLimitedManifestKeys.remove(key)
        CMUXSidebarExtensionLimitedChoiceStore().remove(key)
        xpcHost.grantRequestedAccess(bundleIdentifier: identity.bundleIdentifier)
        self.effectiveGrant = xpcHost.currentEffectiveGrant
        xpcHost.sendSnapshotDidChange()
        render()
    }

    func keepLimitedAccessNative(
        identity: AppExtensionIdentity,
        effectiveGrant: CMUXSidebarExtensionEffectiveGrant
    ) {
        let key = limitedChoiceKeyNative(identity: identity, effectiveGrant: effectiveGrant)
        keptLimitedManifestKeys.insert(key)
        CMUXSidebarExtensionLimitedChoiceStore().insert(key)
        xpcHost.revokeSensitiveAccess(bundleIdentifier: identity.bundleIdentifier)
        self.effectiveGrant = xpcHost.currentEffectiveGrant
        xpcHost.sendSnapshotDidChange()
        render()
    }

    func limitedChoiceKeyNative(
        identity: AppExtensionIdentity,
        effectiveGrant: CMUXSidebarExtensionEffectiveGrant
    ) -> String {
        let readScopes = effectiveGrant.manifest.readScopes
            .map(\.rawValue)
            .sorted()
            .joined(separator: ",")
        let actionScopes = effectiveGrant.manifest.actionScopes
            .map(\.rawValue)
            .sorted()
            .joined(separator: ",")
        return "\(identity.bundleIdentifier)|\(effectiveGrant.manifest.id)|\(effectiveGrant.manifest.minimumAPIVersion.major).\(effectiveGrant.manifest.minimumAPIVersion.minor)|\(readScopes)|\(actionScopes)"
    }

    func pendingPermissionDescriptionsNative(
        effectiveGrant: CMUXSidebarExtensionEffectiveGrant
    ) -> [String] {
        let pendingReadScopes = effectiveGrant.manifest.readScopes.filter {
            !effectiveGrant.readScopes.contains($0)
        }
        let pendingActionScopes = effectiveGrant.manifest.actionScopes.filter {
            !effectiveGrant.actionScopes.contains($0)
        }
        return pendingReadScopes.map(permissionDescriptionNative(scope:))
            + pendingActionScopes.map(permissionDescriptionNative(actionScope:))
    }

    func permissionDescriptionNative(scope: CmuxExtensionScope) -> String {
        switch scope {
        case .workspaceList:
            return String(localized: "sidebar.extensions.permission.workspaceList.detail", defaultValue: "Read workspace IDs and names")
        case .workspaceMetadata:
            return String(localized: "sidebar.extensions.permission.workspaceMetadata.detail", defaultValue: "Read workspace names, branches, unread counts, and selection")
        case .surfaceMetadata:
            return String(localized: "sidebar.extensions.permission.surfaceMetadata.detail", defaultValue: "Read surfaces nested inside each workspace")
        case .workspacePaths:
            return String(localized: "sidebar.extensions.permission.workspacePaths.detail", defaultValue: "Read local workspace and project paths")
        case .notifications:
            return String(localized: "sidebar.extensions.permission.notifications.detail", defaultValue: "Read latest workspace notifications")
        case .networkPorts:
            return String(localized: "sidebar.extensions.permission.networkPorts.detail", defaultValue: "Read listening ports for each workspace")
        case .pullRequests:
            return String(localized: "sidebar.extensions.permission.pullRequests.detail", defaultValue: "Read pull request links associated with workspaces")
        }
    }

    func permissionDescriptionNative(actionScope: CmuxExtensionActionScope) -> String {
        switch actionScope {
        case .createWorkspace:
            return String(localized: "sidebar.extensions.permission.createWorkspace.detail", defaultValue: "Create workspaces")
        case .selectWorkspace:
            return String(localized: "sidebar.extensions.permission.selectWorkspace.detail", defaultValue: "Select a workspace when you click in the extension")
        case .closeWorkspace:
            return String(localized: "sidebar.extensions.permission.closeWorkspace.detail", defaultValue: "Close workspaces from the extension")
        case .createSurface:
            return String(localized: "sidebar.extensions.permission.createSurface.detail", defaultValue: "Create terminal and browser surfaces")
        case .selectSurface:
            return String(localized: "sidebar.extensions.permission.selectSurface.detail", defaultValue: "Select surfaces inside a workspace")
        case .closeSurface:
            return String(localized: "sidebar.extensions.permission.closeSurface.detail", defaultValue: "Close surfaces inside a workspace")
        case .splitSurface:
            return String(localized: "sidebar.extensions.permission.splitSurface.detail", defaultValue: "Create split surfaces")
        case .zoomSurface:
            return String(localized: "sidebar.extensions.permission.zoomSurface.detail", defaultValue: "Toggle surface zoom")
        case .navigateWorkspace:
            return String(localized: "sidebar.extensions.permission.navigateWorkspace.detail", defaultValue: "Navigate between workspaces")
        case .navigateSurface:
            return String(localized: "sidebar.extensions.permission.navigateSurface.detail", defaultValue: "Navigate between surfaces")
        case .openURL:
            return String(localized: "sidebar.extensions.permission.openURL.detail", defaultValue: "Open links from the extension")
        case .createWorkspaceWithPath:
            return String(localized: "sidebar.extensions.permission.createWorkspaceWithPath.detail", defaultValue: "Create workspaces for specific local folders")
        }
    }

    func blockedStatusTextNative(reason: String) -> String {
        switch reason {
        case "connectionInterrupted":
            return String(localized: "sidebar.extensions.blocked.status.connectionInterrupted", defaultValue: "Blocked, connection interrupted")
        case "manifestTimedOut":
            return String(localized: "sidebar.extensions.blocked.status.manifestTimedOut", defaultValue: "Blocked, configuration timed out")
        case "missingManifest":
            return String(localized: "sidebar.extensions.blocked.status.missingManifest", defaultValue: "Blocked, missing configuration")
        case "invalidManifest":
            return String(localized: "sidebar.extensions.blocked.status.invalidManifest", defaultValue: "Blocked, invalid configuration")
        default:
            return String(localized: "sidebar.extensions.blocked.status.failedManifest", defaultValue: "Blocked, configuration unavailable")
        }
    }

    func blockedDetailTextNative(reason: String) -> String {
        switch reason {
        case "connectionInterrupted":
            return String(localized: "sidebar.extensions.blocked.detail.connectionInterrupted", defaultValue: "CMUX lost the extension connection. No workspace data or actions are being shared.")
        case "manifestTimedOut":
            return String(localized: "sidebar.extensions.blocked.detail.manifestTimedOut", defaultValue: "CMUX did not receive this extension's configuration in time. No workspace data or actions are being shared.")
        case "missingManifest":
            return String(localized: "sidebar.extensions.blocked.detail.missingManifest", defaultValue: "CMUX did not receive a sidebar extension configuration, so no workspace data or actions were shared.")
        case "invalidManifest":
            return String(localized: "sidebar.extensions.blocked.detail.invalidManifest", defaultValue: "CMUX rejected this extension's configuration. No workspace data or actions were shared.")
        default:
            return String(localized: "sidebar.extensions.blocked.detail.failedManifest", defaultValue: "CMUX could not load this extension's configuration. No workspace data or actions were shared.")
        }
    }
}

private extension CmuxExtensionScope {
    var displayName: String {
        switch self {
        case .workspaceList:
            return String(localized: "sidebar.extensions.scope.workspaceList", defaultValue: "Workspace list")
        case .workspaceMetadata:
            return String(localized: "sidebar.extensions.scope.workspaceMetadata", defaultValue: "Workspace metadata")
        case .surfaceMetadata:
            return String(localized: "sidebar.extensions.scope.surfaceMetadata", defaultValue: "Surface metadata")
        case .workspacePaths:
            return String(localized: "sidebar.extensions.scope.workspacePaths", defaultValue: "Workspace paths")
        case .notifications:
            return String(localized: "sidebar.extensions.scope.notifications", defaultValue: "Notifications")
        case .networkPorts:
            return String(localized: "sidebar.extensions.scope.networkPorts", defaultValue: "Network ports")
        case .pullRequests:
            return String(localized: "sidebar.extensions.scope.pullRequests", defaultValue: "Pull requests")
        }
    }
}

private extension CmuxExtensionActionScope {
    var displayName: String {
        switch self {
        case .createWorkspace:
            return String(localized: "sidebar.extensions.actionScope.createWorkspace", defaultValue: "Create workspaces")
        case .selectWorkspace:
            return String(localized: "sidebar.extensions.actionScope.selectWorkspace", defaultValue: "Select workspaces")
        case .closeWorkspace:
            return String(localized: "sidebar.extensions.actionScope.closeWorkspace", defaultValue: "Close workspaces")
        case .createSurface:
            return String(localized: "sidebar.extensions.actionScope.createSurface", defaultValue: "Create surfaces")
        case .selectSurface:
            return String(localized: "sidebar.extensions.actionScope.selectSurface", defaultValue: "Select surfaces")
        case .closeSurface:
            return String(localized: "sidebar.extensions.actionScope.closeSurface", defaultValue: "Close surfaces")
        case .splitSurface:
            return String(localized: "sidebar.extensions.actionScope.splitSurface", defaultValue: "Split surfaces")
        case .zoomSurface:
            return String(localized: "sidebar.extensions.actionScope.zoomSurface", defaultValue: "Zoom surfaces")
        case .navigateWorkspace:
            return String(localized: "sidebar.extensions.actionScope.navigateWorkspace", defaultValue: "Navigate workspaces")
        case .navigateSurface:
            return String(localized: "sidebar.extensions.actionScope.navigateSurface", defaultValue: "Navigate surfaces")
        case .openURL:
            return String(localized: "sidebar.extensions.actionScope.openURL", defaultValue: "Open URLs")
        case .createWorkspaceWithPath:
            return String(localized: "sidebar.extensions.actionScope.createWorkspaceWithPath", defaultValue: "Create workspaces with paths")
        }
    }
}

@MainActor
private final class CMUXSidebarExtensionHostXPC {
    private static let untrustedScopes: Set<CmuxExtensionScope> = []
    private static let untrustedActionScopes: Set<CmuxExtensionActionScope> = []
    private static let manifestRequestTimeout: Duration = .seconds(5)

    private var connection: NSXPCConnection?
    private var extensionProxy: CMUXSidebarExtensionXPC?
    private var exportedObject: CMUXSidebarHostXPCObject?
    private var snapshotProvider: (() -> CmuxSidebarSnapshot)?
    private var actionHandler: ((CmuxSidebarAction) -> CmuxSidebarActionResult)?
    private var allowedScopes = untrustedScopes
    private var allowedActionScopes = untrustedActionScopes
    private var connectionGeneration: UInt64 = 0
    private var bundleIdentifier: String?
    private var currentManifest: CmuxExtensionManifest?
    private var onGrantChanged: ((CMUXSidebarExtensionEffectiveGrant?) -> Void)?
    private var onManifestBlocked: ((String?) -> Void)?
    private var onPresentationChanged: ((CmuxSidebarPresentation?) -> Void)?
    private var awaitingManifestGeneration: UInt64?
    private var manifestRequestTimeoutTask: Task<Void, Never>?
    private let grantStore = CMUXSidebarExtensionGrantStore()

    var currentEffectiveGrant: CMUXSidebarExtensionEffectiveGrant? {
        guard let bundleIdentifier, let currentManifest else { return nil }
        return grantStore.effectiveGrant(bundleIdentifier: bundleIdentifier, manifest: currentManifest)
    }

    func update(
        snapshotProvider: @escaping @MainActor () -> CmuxSidebarSnapshot,
        actionHandler: @escaping @MainActor (CmuxSidebarAction) -> CmuxSidebarActionResult
    ) {
        self.snapshotProvider = snapshotProvider
        self.actionHandler = actionHandler
        exportedObject?.actionHandler = scopedActionHandler(actionHandler)
        updateExportedSnapshotFilter()
    }

    func attach(
        connection: NSXPCConnection,
        bundleIdentifier: String,
        snapshotProvider: @escaping @MainActor () -> CmuxSidebarSnapshot,
        actionHandler: @escaping @MainActor (CmuxSidebarAction) -> CmuxSidebarActionResult,
        onGrantChanged: @escaping @MainActor (CMUXSidebarExtensionEffectiveGrant?) -> Void,
        onManifestBlocked: @escaping @MainActor (String?) -> Void,
        onPresentationChanged: @escaping @MainActor (CmuxSidebarPresentation?) -> Void
    ) {
        invalidate()
        connectionGeneration += 1
        let generation = connectionGeneration
        let exportedObject = CMUXSidebarHostXPCObject(
            snapshotProvider: { Self.untrustedSnapshot(from: snapshotProvider()) },
            actionHandler: scopedActionHandler(actionHandler),
            onAcceptedAction: { [weak self] in
                self?.sendSnapshotDidChange()
            },
            onPresentationChanged: onPresentationChanged,
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
        self.onManifestBlocked = onManifestBlocked
        self.onPresentationChanged = onPresentationChanged
        self.allowedScopes = Self.untrustedScopes
        self.allowedActionScopes = Self.untrustedActionScopes
        self.extensionProxy = connection.remoteObjectProxy as? CMUXSidebarExtensionXPC
        connection.resume()
        requestManifestThenSendInitialSnapshot(generation: generation)
    }

    func sendSnapshotDidChange() {
        guard let snapshotProvider else { return }
        sendSnapshotDidChange(snapshotProvider())
    }

    func sendSnapshotDidChange(_ snapshot: CmuxSidebarSnapshot) {
        guard let extensionProxy else { return }
        do {
            extensionProxy.sidebarSnapshotDidChange(
                try CmuxSidebarXPCCodec.encodeSnapshot(
                    snapshot.filtered(for: allowedScopes, actionScopes: allowedActionScopes)
                )
            )
        } catch {
#if DEBUG
            cmuxDebugLog("extension.sidebar.xpc.snapshot.encode.failed error=\(error.localizedDescription)")
#endif
        }
    }

    func performPresentationAction(_ actionID: String) {
        guard let extensionProxy else { return }
        extensionProxy.performSidebarPresentationAction(actionID as NSString) { error in
#if DEBUG
            if let error {
                cmuxDebugLog("extension.sidebar.presentation.action.failed error=\(error)")
            }
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
        cancelManifestRequestTimeout()
        blockUntrustedExtension(reason: "connectionInterrupted")
        updateExportedSnapshotFilter()
    }

    private func clearConnection(ifCurrentGeneration generation: UInt64) {
        guard connectionGeneration == generation else { return }
        cancelManifestRequestTimeout()
        connection = nil
        extensionProxy = nil
        exportedObject = nil
        allowedScopes = Self.untrustedScopes
        allowedActionScopes = Self.untrustedActionScopes
        bundleIdentifier = nil
        currentManifest = nil
        onGrantChanged?(nil)
        onGrantChanged = nil
        onManifestBlocked?(nil)
        onManifestBlocked = nil
        onPresentationChanged?(nil)
        onPresentationChanged = nil
    }

    private func requestManifestThenSendInitialSnapshot(generation: UInt64) {
        guard let extensionProxy,
              let requestExtensionManifest = extensionProxy.requestExtensionManifest else {
            blockUntrustedExtension(reason: "missingManifest")
            updateExportedSnapshotFilter()
            return
        }
        beginManifestRequestTimeout(generation: generation)
        requestExtensionManifest { [weak self] payload, error in
            Task { @MainActor [generation] in
                guard let self else { return }
                guard self.connectionGeneration == generation else { return }
                guard self.awaitingManifestGeneration == generation else { return }
                self.cancelManifestRequestTimeout()
                if let payload {
                    do {
                        let manifest = try CmuxSidebarXPCCodec.decodeManifest(payload)
                        try validateSidebarManifest(manifest)
                        self.applyManifest(manifest)
                    } catch {
                        self.blockUntrustedExtension(reason: "invalidManifest")
#if DEBUG
                        cmuxDebugLog("extension.sidebar.manifest.invalid error=\(error.localizedDescription)")
#endif
                    }
                } else {
                    self.blockUntrustedExtension(reason: "manifestRequestFailed")
                    if let error {
#if DEBUG
                        cmuxDebugLog("extension.sidebar.manifest.failed error=\(error)")
#endif
                    }
                }
                self.updateExportedSnapshotFilter()
                if self.currentEffectiveGrant?.needsAdditionalApproval == false {
                    self.sendSnapshotDidChange()
                }
            }
        }
    }

    private func beginManifestRequestTimeout(generation: UInt64) {
        cancelManifestRequestTimeout()
        awaitingManifestGeneration = generation
        manifestRequestTimeoutTask = Task { @MainActor [weak self, generation] in
            do {
                try await Task.sleep(for: Self.manifestRequestTimeout)
            } catch {
                return
            }
            guard let self,
                  self.connectionGeneration == generation,
                  self.awaitingManifestGeneration == generation else { return }
            self.cancelManifestRequestTimeout()
            self.blockUntrustedExtension(reason: "manifestTimedOut")
            self.updateExportedSnapshotFilter()
        }
    }

    private func cancelManifestRequestTimeout() {
        awaitingManifestGeneration = nil
        manifestRequestTimeoutTask?.cancel()
        manifestRequestTimeoutTask = nil
    }

    func grantRequestedAccess(bundleIdentifier: String) {
        guard self.bundleIdentifier == bundleIdentifier, let currentManifest else { return }
        grantStore.grantRequestedAccess(bundleIdentifier: bundleIdentifier, manifest: currentManifest)
        applyManifest(currentManifest)
        sendSnapshotDidChange()
    }

    func revokeSensitiveAccess(bundleIdentifier: String) {
        guard self.bundleIdentifier == bundleIdentifier, let currentManifest else { return }
        grantStore.revokeSensitiveAccess(bundleIdentifier: bundleIdentifier, manifest: currentManifest)
        applyManifest(currentManifest)
        sendSnapshotDidChange()
    }

    private func applyManifest(_ manifest: CmuxExtensionManifest) {
        cancelManifestRequestTimeout()
        currentManifest = manifest
        guard let bundleIdentifier else {
            allowedScopes = Self.untrustedScopes
            allowedActionScopes = Self.untrustedActionScopes
            onGrantChanged?(nil)
            return
        }
        let effectiveGrant = grantStore.effectiveGrant(bundleIdentifier: bundleIdentifier, manifest: manifest)
        allowedScopes = effectiveGrant.readScopes
        allowedActionScopes = effectiveGrant.actionScopes
        onManifestBlocked?(nil)
        onGrantChanged?(effectiveGrant)
    }

    private func filteredSnapshot(from snapshotProvider: () -> CmuxSidebarSnapshot) -> CmuxSidebarSnapshot {
        snapshotProvider().filtered(for: allowedScopes, actionScopes: allowedActionScopes)
    }

    private func updateExportedSnapshotFilter() {
        guard let snapshotProvider else { return }
        exportedObject?.snapshotProvider = { [weak self] in
            guard let self else {
                return Self.untrustedSnapshot(from: snapshotProvider())
            }
            return filteredSnapshot(from: snapshotProvider)
        }
    }

    private func scopedActionHandler(
        _ actionHandler: @escaping @MainActor (CmuxSidebarAction) -> CmuxSidebarActionResult
    ) -> (@MainActor (CmuxSidebarAction) -> CmuxSidebarActionResult) {
        { [weak self] action in
            guard let self,
                  self.currentManifest != nil,
                  self.allowedActionScopes.isSuperset(of: action.requiredScopes) else {
                return CmuxSidebarActionResult(
                    accepted: false,
                    message: String(localized: "sidebar.extensions.action.scopeRejected", defaultValue: "Extension action is not granted")
                )
            }
            return actionHandler(action)
        }
    }

    private func blockUntrustedExtension(reason: String) {
        cancelManifestRequestTimeout()
        allowedScopes = Self.untrustedScopes
        allowedActionScopes = Self.untrustedActionScopes
        currentManifest = nil
        onGrantChanged?(nil)
        onManifestBlocked?(reason)
#if DEBUG
        cmuxDebugLog("extension.sidebar.manifest.blocked reason=\(reason)")
#endif
    }

    private static func untrustedSnapshot(from snapshot: CmuxSidebarSnapshot) -> CmuxSidebarSnapshot {
        CmuxSidebarSnapshot(
            apiVersion: snapshot.apiVersion,
            sequence: snapshot.sequence,
            selectedWorkspaceID: nil,
            workspaces: []
        )
    }
}

private final class CMUXSidebarHostXPCObject: NSObject, CMUXSidebarHostXPC {
    @MainActor var snapshotProvider: () -> CmuxSidebarSnapshot
    @MainActor var actionHandler: (CmuxSidebarAction) -> CmuxSidebarActionResult
    @MainActor var onAcceptedAction: () -> Void
    @MainActor var onPresentationChanged: (CmuxSidebarPresentation) -> Void
    @MainActor var isCurrentGeneration: () -> Bool

    @MainActor
    init(
        snapshotProvider: @escaping @MainActor () -> CmuxSidebarSnapshot,
        actionHandler: @escaping @MainActor (CmuxSidebarAction) -> CmuxSidebarActionResult,
        onAcceptedAction: @escaping @MainActor () -> Void,
        onPresentationChanged: @escaping @MainActor (CmuxSidebarPresentation) -> Void,
        isCurrentGeneration: @escaping @MainActor () -> Bool
    ) {
        self.snapshotProvider = snapshotProvider
        self.actionHandler = actionHandler
        self.onAcceptedAction = onAcceptedAction
        self.onPresentationChanged = onPresentationChanged
        self.isCurrentGeneration = isCurrentGeneration
    }

    func requestSidebarSnapshot(reply: @escaping (NSData?, NSString?) -> Void) {
        Task { @MainActor in
            guard isCurrentGeneration() else {
                reply(nil, String(localized: "sidebar.extensions.action.staleConnection", defaultValue: "Extension connection is no longer active") as NSString)
                return
            }
            do {
                reply(try CmuxSidebarXPCCodec.encodeSnapshot(snapshotProvider()), nil)
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
                let action = try CmuxSidebarXPCCodec.decodeAction(payload)
                let result = actionHandler(action)
                reply(try CmuxSidebarXPCCodec.encodeActionResult(result), nil)
                if result.accepted {
                    onAcceptedAction()
                }
            } catch {
                reply(nil, error.localizedDescription as NSString)
            }
        }
    }

    func sidebarPresentationDidChange(_ payload: NSData) {
        Task { @MainActor in
            guard isCurrentGeneration() else { return }
            do {
                onPresentationChanged(try CmuxSidebarXPCCodec.decodePresentation(payload))
            } catch {
#if DEBUG
                cmuxDebugLog("extension.sidebar.presentation.decode.failed error=\(error.localizedDescription)")
#endif
            }
        }
    }
}
