import CmuxCloudBannerCore
import CmuxCloud
import AppKit
import CmuxCloudMachines
import CmuxSettings
import CmuxSurfaceCatalogModel
import Combine
import OSLog
import SwiftUI

/// Right-sidebar Machines tab: the user's cloud machine fleet as a Finder-like
/// tree (machine → Workspaces → terminals, Ports, Displays, Terminals). Matches the
/// Vault/Feed visual language — compact 13pt rows, full-width hover
/// backgrounds, chrome-pill control bar. Outline rows receive immutable
/// snapshots plus closure bundles only (snapshot-boundary rule); every mutation
/// routes through the shared Cloud VM action path or the Cloud tree service.
struct MachinesPanelView: View {
    private static let coderouterLogger = Logger(subsystem: "com.cmuxterm.app", category: "coderouter-accounts")
    @StateObject var viewModel: MachinesPanelViewModel
    @State private var devicesModel: DevicesPanelViewModel
    @State private var discoveryManaged = ManagedDevicePolicy().isDeviceDiscoveryDisabled
    @State private var incomingAccessManaged = ManagedDevicePolicy().isIncomingDeviceAccessDisabled
    @State private var expansionStore = CloudTreeExpansionStore()
    /// The explicit Cloud VPN's state (`cmux vpn up`), shown as a banner while
    /// it is starting, waiting for the extension approval, up, or failed.
    @State private var tunnelStatus = CloudTunnelStatusModel()
    @State private var devBackend = DevBackendStartup()
    @State var billingPlanLoaded = false
    @State private var coderouter = CloudTreeCoderouterSection()
    /// The CodeRouter organization matched to the selected cmux team. Keep it
    /// beside the account snapshot so create actions can target that exact
    /// organization instead of the CLI's mutable global scope.
    @State private var coderouterDestination: (teamID: String, identityID: String?, organizationID: String, supportsTeamOption: Bool)?
    /// Bumped by the section's refresh icon; restarting the refresh loop keeps one owner of the CLI reads.
    @State private var coderouterRefreshRequest = 0
    @State private var bannerDismissals: CloudBannerDismissalStore
    /// The owning window's selection stream lets the Cloud tree update before
    /// the next machine/catalog refresh arrives.
    @State private var selectedWorkspacePublisher: AnyPublisher<UUID?, Never>
    /// The tree's visual preset; the debug gallery's "Use" buttons write this,
    /// and @AppStorage re-renders the live panel the moment it changes.
    @AppStorage(CloudTreeStyleStore.defaultsKey) private var cloudTreeStyleID: String = CloudTreeStyle.defaultStyle.id
    let chromeBackgroundColor: NSColor
    var tabManager: TabManager? = nil
    let teamPickerPresentation: CloudTeamPickerPresentation?
    let activationCoordinator: CloudActivationCoordinator

    init(
        chromeBackgroundColor: NSColor,
        machinePinStore: CloudMachinePinStore? = nil,
        devicesModel: DevicesPanelViewModel? = nil,
        tabManager: TabManager? = nil,
        teamPickerPresentation: CloudTeamPickerPresentation? = nil,
        activationCoordinator: CloudActivationCoordinator,
        viewModel: MachinesPanelViewModel? = nil
    ) {
        self.chromeBackgroundColor = chromeBackgroundColor
        self.tabManager = tabManager
        self.teamPickerPresentation = teamPickerPresentation
        self.activationCoordinator = activationCoordinator
        _selectedWorkspacePublisher = State(initialValue:
            tabManager?.selectedTabIdPublisher.eraseToAnyPublisher()
                ?? Just(nil).eraseToAnyPublisher()
        )
        _bannerDismissals = State(
            initialValue: AppDelegate.shared?.cloudBannerDismissalStore
                ?? CloudBannerDismissalStore(defaults: .standard)
        )
        _viewModel = StateObject(wrappedValue: viewModel ?? MachinesPanelViewModel(
            machinePinStore: machinePinStore,
            localWorkspacesProvider: { [weak tabManager] in
                guard let tabManager else { return [] }
                return tabManager.tabs.map {
                    CloudTreeLocalWorkspace(id: $0.id, title: $0.title, isSelected: $0.id == tabManager.selectedTabId)
                }
            }
        ))
        _devicesModel = State(initialValue: devicesModel ?? DevicesPanelViewModel())
    }

    var accountFlow: HostAccountFlow? {
        AppDelegate.shared?.auth?.accountFlow
    }

    var authState: CloudVMPanelAuthState {
        CloudVMPanelAuthState.resolve(
            isAuthenticated: accountFlow?.isAuthenticated == true,
            // Keep the embedded sign-in screen mounted while the browser is
            // waiting for the callback. Only session restore/completion owns
            // the panel-wide checking state.
            isWorkingOnAuth: accountFlow?.isCompletingSignIn == true
        )
    }

    private var includesDevices: Bool {
        return DevicesFeature.isEnabled && (devicesModel.preferences?.discoveryEnabled ?? DevicesFeature.localOptIn(defaults: .standard))
    }

    private var includesCloud: Bool {
        return CloudMachinesFeature.isEnabled
    }

    private var treeSource: CloudTreeMachineSource { .cloudWithDevicesSection }

    private var treeSnapshot: SurfaceCatalogSnapshot {
        viewModel.visibleCatalog.applyingDeviceVisibility(
            includesCloud: includesCloud,
            includesDevices: includesDevices,
            hiddenMacIDs: devicesModel.preferences?.hiddenMacIDs ?? []
        )
    }

    private func refreshMachines() {
        if includesCloud { viewModel.refresh(tree: true) }
        if includesDevices { devicesModel.refresh() }
    }

    var body: some View {
        activationContent
        .onAppear {
            activationCoordinator.reconcile()
            syncPolling(for: authState)
        }
        .onChange(of: devicesModel.preferences?.discoveryEnabled) { _, _ in syncPolling(for: authState) }
        .onChange(of: activationCoordinator.state) { _, _ in syncPolling(for: authState) }
        .onChange(of: activationCoordinator.isPreparing) { _, _ in syncPolling(for: authState) }
        .onReceive(NotificationCenter.default.publisher(for: DeviceSurfaceProviderRegistry.revealDeviceNotification)) { _ in
            devicesModel.consumePendingReveal()
        }
        .onChange(of: authState) { _, state in
            syncPolling(for: state)
            viewModel.machinePinStore?.refreshScope()
        }
        // Pins are scoped per account and team; a switch re-reads the scope and
        // the fleet so the tree never shows another scope's pins.
        .onChange(of: accountFlow?.confirmedTeamID) { _, _ in
            coderouterDestination = nil
            coderouter.accounts = []
            viewModel.refreshAccountScope()
        }
        .onChange(of: accountFlow?.currentIdentity?.id) { _, _ in
            coderouterDestination = nil
            coderouter.accounts = []
            viewModel.refreshAccountScope()
        }
        .onReceive(selectedWorkspacePublisher) { selectedWorkspaceID in
            viewModel.refreshLocalWorkspaces(selectedWorkspaceID: selectedWorkspaceID)
        }
        .onDisappear {
            viewModel.stopPolling()
            viewModel.cancelCloudAgentTask()
        }
        .task(id: CoderouterRefreshKey(teamID: accountFlow?.confirmedTeamID, identityID: accountFlow?.currentIdentity?.id, request: coderouterRefreshRequest)) {
            while !Task.isCancelled {
                await refreshCoderouterAccounts()
                coderouter.isRefreshing = false
                do {
                    try await ContinuousClock().sleep(for: .seconds(5))
                } catch {
                    return
                }
            }
        }
        .task {
            for await _ in ManagedDevicePolicy.changeSignals() {
                let policy = ManagedDevicePolicy()
                discoveryManaged = policy.isDeviceDiscoveryDisabled
                incomingAccessManaged = policy.isIncomingDeviceAccessDisabled
            }
        }
        .task {
            await tunnelStatus.observe(AppDelegate.shared?.cloudTunnelCoordinator)
        }
        .task(id: accountFlow?.currentIdentity?.id) {
            guard let accountFlow, accountFlow.isAuthenticated,
                  let requestedIdentityID = accountFlow.currentIdentity?.id else {
                billingPlanLoaded = false
                return
            }
            // The panel is rebuilt whenever the sidebar switches modes. Start
            // from the account's last answer so Enable Cloud / Upgrade stays
            // on screen while it refreshes, instead of flashing "Checking…".
            billingPlanLoaded = accountFlow.hasLoadedBillingPlan
            // The enable action is available while the entitlement is unknown.
            // The response itself is the synchronization event.
            billingPlanLoaded = true
            await accountFlow.refreshBillingPlan()
            guard !Task.isCancelled,
                  accountFlow.isAuthenticated,
                  accountFlow.currentIdentity?.id == requestedIdentityID else { return }
            billingPlanLoaded = true
        }
        .task(id: devBackend.attempt) {
            await devBackend.observe()
            if devBackend.status?.isReady == true, !activationCoordinator.isPreparing { viewModel.refresh() }
        }
        .accessibilityIdentifier("CloudMachinesPanel")
    }

    @ViewBuilder
    var authenticatedContent: some View {
        if includesCloud {
            controlBar
            CloudNewMachineButton {
                _ = AppDelegate.shared?.performNewCloudMachineAction(
                    tabManager: tabManager,
                    preferredWindow: tabManager?.window,
                    debugSource: "cloudTree.newMachineButton"
                )
            }
        }
        if includesCloud {
            MachinesPanelBanners(
                tunnelBanner: tunnelStatus.banner, plan: viewModel.plan,
                bannerDismissals: bannerDismissals, chromeBackgroundColor: chromeBackgroundColor
            )
        }
        if includesCloud, let status = devBackend.status, !status.isReady {
            VStack(spacing: 12) {
                if status.isFailure {
                    Image(systemName: "exclamationmark.icloud")
                } else {
                    ProgressView().controlSize(.small)
                }
                Text(status.message)
                    .cmuxFont(size: 12)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                if status.isFailure {
                    Button(String(localized: "devBackend.retry", defaultValue: "Try again")) { devBackend.retry() }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityIdentifier("CloudDevBackendStartup")
        } else if isTeamChangePending {
            teamScopeLoading
        } else {
            content
        }
    }

    private func syncPolling(for state: CloudVMPanelAuthState) {
        switch state {
        case .signedIn:
            if includesCloud && !activationCoordinator.isPreparing {
                viewModel.startPolling()
            } else {
                viewModel.stopPolling()
                viewModel.resetForAuthTransition()
            }
            if includesDevices { devicesModel.start() }
            viewModel.readCatalog()
        case .checking, .signedOut:
            viewModel.stopPolling()
            viewModel.resetForAuthTransition()
        }
    }

    private var cloudStatus: some View {
        MachinesCloudStatus(
            listStatus: toolbarListStatus,
            listError: viewModel.lastErrorDescription,
            treeError: visibleTreeErrorDescription,
            treeHint: viewModel.treeHint,
            onDismissStale: { bannerDismissals.dismiss(id: "machines.stale", signature: $0) },
            onDismissTreeError: { error in
                bannerDismissals.dismiss(id: "machines.tree-error", signature: error)
            },
            performListStatusAction: performListStatusAction
        )
    }

    private var visibleTreeErrorDescription: String? {
        guard let error = viewModel.treeErrorDescription,
              !bannerDismissals.isDismissed(id: "machines.tree-error", signature: error) else {
            return nil
        }
        return error
    }

    /// Only while cached machines stay on screen; a dismissed failure stays
    /// hidden until its error changes.
    private var toolbarListStatus: MachineListStatus? {
        guard !viewModel.visibleMachines.isEmpty, let status = viewModel.listStatus else { return nil }
        if case .failed = status, let error = viewModel.lastErrorDescription,
           bannerDismissals.isDismissed(id: "machines.stale", signature: error) { return nil }
        return status
    }

    /// Renders the Cloud team header with its team scope and Invite action.
    var controlBar: some View {
        CloudTeamPickerHeader(
            accountFlow: accountFlow,
            presentation: teamPickerPresentation,
            chromeBackgroundColor: chromeBackgroundColor,
            isRefreshing: viewModel.isLoading || devicesModel.isRefreshing,
            onRefresh: refreshMachines,
            onNewMachine: requestNewMachine,
            status: { cloudStatus }
        )
        .disabled(activationCoordinator.isPreparing)
    }

    @ViewBuilder
    private var content: some View {
        // Show the empty state exactly when the outline would render zero
        // rows. The builder owns that decision (the tree is cloud-only while
        // `includesLocalMachine` is off); deciding it here from the raw
        // catalog previously left a blank panel for a signed-in account with
        // no machines, because the catalog's This Mac entry counted as a row
        // the tree never drew.
        if includesCloud && includesDevices && viewModel.visibleMachines.isEmpty, let status = viewModel.listStatus {
            VStack(spacing: 0) {
                MachinesListStatusNotice(status: status, perform: performListStatusAction)
                machinesList
            }
        } else if CloudTreeNodeBuilder.isEmpty(
            machines: includesCloud ? viewModel.visibleMachines : [],
            pendingCreates: includesCloud ? viewModel.pendingCreates : [],
            snapshot: treeSnapshot,
            source: treeSource
        ) {
            emptyState
        } else {
            machinesList
        }
    }

    var authCheckingState: some View {
        VStack(spacing: 10) {
            Spacer()
            ProgressView()
                .controlSize(.small)
            Text(String(
                localized: "machines.auth.checking",
                defaultValue: "Checking your cmux account…"
            ))
            .cmuxFont(size: 13)
            .foregroundColor(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("CloudMachinesAuthCheckingView")
    }

    @ViewBuilder
    var authGate: some View {
        if let accountFlow {
            CloudMachinesSignInView(accountFlow: accountFlow)
        } else {
            VStack(spacing: 12) {
                Spacer()
                Image(systemName: "person.crop.circle.badge.plus")
                    .font(.system(size: 28, weight: .light))
                    .foregroundColor(.secondary.opacity(0.7))
                Text(String(
                    localized: "machines.auth.title",
                    defaultValue: "Sign in to use Cloud Machines"
                ))
                .cmuxFont(size: 13, weight: .semibold)
                Text(String(
                    localized: "machines.auth.subtitle",
                    defaultValue: "Sign in to see and manage the machines in your cmux account."
                ))
                .cmuxFont(size: 12)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityIdentifier("CloudMachinesSignInUnavailableView")
        }
    }

    private struct CloudMachinesSignInView: View {
        let accountFlow: HostAccountFlow
        @State private var signInModel: AccountSignInModel

        init(accountFlow: HostAccountFlow) {
            self.accountFlow = accountFlow
            _signInModel = State(initialValue: AccountSignInModel(flow: accountFlow))
        }

        var body: some View {
            // One header only: the shared sign-in view carries the pane's
            // copy through its idle state, and its later stages (waiting,
            // failed, signed in) stand alone instead of stacking under a
            // second title.
            AccountSignInView(
                model: signInModel,
                automaticallyStartsSignIn: false,
                idleTitle: String(
                    localized: "machines.auth.title",
                    defaultValue: "Sign in to use Cloud Machines"
                ),
                idleSubtitle: String(
                    localized: "machines.auth.subtitle",
                    defaultValue: "Sign in to see and manage the machines in your cmux account."
                )
            )
            .frame(maxWidth: 440)
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityIdentifier("CloudMachinesSignInView")
        }
    }

    private func requestNewMachine() {
        NewMachineSheetPresenter.shared.presentNewMachine(
            plan: viewModel.plan,
            memoryOptionsMb: viewModel.memoryOptionsMb,
            lockedMemoryOptionsMb: viewModel.lockedMemoryOptionsMb,
            memoryUpgradePlanId: viewModel.memoryUpgradePlanId,
            memoryUpgradePlansByMb: viewModel.memoryUpgradePlansByMb,
            preferredWindow: tabManager?.window ?? NSApp.keyWindow ?? NSApp.mainWindow,
            coordinator: viewModel.createCoordinator
        )
    }
    /// Binds the shared Cloud and Devices tree above the outline's snapshot boundary.
    private var machinesList: some View {
        var machineActions = MachineRowActions.bound(
            onDidMutate: { [weak viewModel] in
                viewModel?.endOperation()
                viewModel?.refresh(tree: true)
            },
            onRename: { [weak viewModel] machine, label in
                viewModel?.beginOptimisticRename(id: machine.id, label: label)
            },
            onRenameDidComplete: { [weak viewModel] in
                viewModel?.finishOptimisticRename()
            }
        )
        // The list endpoint is authoritative for the caller's plan-sized
        // memory ladder. Feed it into the menu so Pro users do not select a
        // Max-only size and wait for a server rejection.
        let planMemoryGiB = viewModel.memoryOptionsMb.map { $0 / 1024 }.filter { $0 > 0 }
        machineActions.resizeMemoryOptionsGiB = planMemoryGiB
        // The image ladder pairs one vCPU with every 2 GB (8 GB = 4 vCPU).
        machineActions.resizeCPUOptions = planMemoryGiB.map { max(1, ($0 + 1) / 2) }
        viewModel.bindMachineOrdering(to: &machineActions)
        machineActions.create = MachineCreateRowActions.bound(coordinator: viewModel.createCoordinator)
        var nodeActions = CloudTreeNodeActions.bound(
            navigationHost: AppDelegate.makeCloudTerminalNavigationHost(),
            catalog: { SurfaceCatalog.shared },
            selectedWorkspaceID: { tabManager?.selectedTabId },
            selectLocalWorkspace: { workspaceID in
                tabManager?.selectedTabId = workspaceID
            },
            onDidMutate: { [weak viewModel] in viewModel?.endOperation() },
            onFailure: { [weak viewModel] description in viewModel?.noteTreeFailure(description) },
            onHint: { [weak viewModel] hint in viewModel?.noteTreeHint(hint) },
            refresh: { refreshMachines() },
            refreshMachine: { [weak viewModel] in viewModel?.refreshMachine($0) },
            workspaceCreationHost: { tabManager.map { CloudWorkspaceCreationHost(manager: $0) } }
        )
        nodeActions.needsDevicePairing = { [weak devicesModel] machine in
            devicesModel?.needsPairing(machine) ?? false
        }
        nodeActions.hideDevice = { [weak devicesModel] machine in
            guard let instance = machine.deviceInstance else { return }
            Task { await devicesModel?.preferences?.setHidden(instance, hidden: true) }
        }
        nodeActions.setDeviceDiscovery = { [weak devicesModel] enabled in
            Task { await devicesModel?.preferences?.setDiscoveryEnabled(enabled) }
        }
        nodeActions.setDeviceIncomingAccess = { [weak devicesModel] enabled in
            Task { await devicesModel?.preferences?.setIncomingAccessEnabled(enabled) }
        }
        // The header "+" is Cmd-Y from this window: same gates, sheet, optimistic create, and no workspace until the sheet completes.
        nodeActions.newMachine = { [weak tabManager] in
            _ = AppDelegate.shared?.performNewCloudMachineAction(
                tabManager: tabManager,
                preferredWindow: tabManager?.window,
                debugSource: "cloudTree.cloudMachinesSection"
            )
        }
        nodeActions.newWorkspaceOnResolvedMachine = CloudTreeNodeActions.resolvedWorkspaceCreationAction(tabManager: tabManager)
        nodeActions.addCoderouterAccount = { [self] provider in addCoderouterAccount(provider) }
        nodeActions.removeCoderouterAccount = { [self] account in removeCoderouterAccount(account) }
        nodeActions.refreshCoderouter = { [self] in requestCoderouterRefresh() }
        return CloudTreeOutlineView(
            machines: includesCloud ? viewModel.sidebarMachines : [], pendingMachineDeletions: MachineDeleteCoordinator.shared.pendingMachineIDs,
            pendingCreates: includesCloud ? viewModel.pendingCreates : [],
            adoptedOperationIDs: includesCloud ? viewModel.adoptedOperationIDs : [:],
            snapshot: treeSnapshot,
            localWorkspaces: viewModel.localWorkspaces,
            unreadTerminalIDs: viewModel.unreadTerminalIDs,
            machineActions: machineActions,
            nodeActions: nodeActions,
            expansionStore: expansionStore, organizationStore: SurfaceCatalog.shared.sidebarOrganization, organizationState: SurfaceCatalog.shared.sidebarOrganization.state,
            style: CloudTreeStyle.preset(id: cloudTreeStyleID) ?? .defaultStyle,
            onDragStateChange: { [weak viewModel] dragging in viewModel?.setTreeDragging(dragging) },
            source: treeSource,
            devicesSection: CloudTreeDevicesSection(
                discoveryEnabled: includesDevices,
                incomingAccessEnabled: devicesModel.preferences?.incomingAccessEnabled ?? false,
                discoveryManaged: discoveryManaged,
                incomingAccessManaged: incomingAccessManaged, available: DevicesFeature.isAvailable(), isRefreshing: devicesModel.isRefreshing
            ),
            coderouter: coderouter,
            showsCloudVPNWarning: tunnelStatus.status?.state == .off,
            canCreateCloudMachine: includesCloud,
            cloudMachinesUsage: includesCloud ? viewModel.visibleUsage : nil, cloudMachinesRefresh: includesCloud ? .init(isRefreshing: viewModel.isRefreshingOnRequest || viewModel.isRenamingMachine) : nil,
            reveal: devicesModel.revealRequest,
            creationReveal: SurfaceCatalog.shared.cloudWorkspaceCreationCoordinator.reveals.reveal(for: tabManager)
        )
        .accessibilityIdentifier("CloudMachinesTree")
    }

    @MainActor
    private func refreshCoderouterAccounts() async {
        guard let teamID = accountFlow?.confirmedTeamID,
              !teamID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            coderouter.accounts = []
            coderouterDestination = nil
            return
        }
        let previousDestination = coderouterDestination
        let knownOrganizationID: String?
        if previousDestination?.teamID == teamID,
           previousDestination?.identityID == accountFlow?.currentIdentity?.id {
            knownOrganizationID = previousDestination?.organizationID
        } else {
            knownOrganizationID = nil
        }
        // A refresh is the freshness boundary for the team-to-organization
        // mapping. Do not let a slow or failed read authorize a new account
        // against the previous snapshot.
        coderouterDestination = nil
        let identityID = accountFlow?.currentIdentity?.id
        do {
            let teamName = accountFlow?.availableTeams.first(where: { $0.id == teamID })?.displayName
            Self.coderouterLogger.info("Refreshing CodeRouter accounts for cmux team ID \(teamID, privacy: .public), name \(teamName ?? "<nil>", privacy: .public)")
            let snapshot = try await CoderouterCLIAccountReader.snapshot(
                for: teamID,
                name: teamName,
                knownOrganizationID: knownOrganizationID
            )
            // A team switch or manual refresh cancelled this read; its result is stale.
            guard !Task.isCancelled,
                  accountFlow?.confirmedTeamID == teamID,
                  accountFlow?.currentIdentity?.id == identityID else { return }
            coderouterDestination = (teamID, identityID, snapshot.organizationID, snapshot.supportsTeamOption)
            coderouter.accounts = snapshot.accounts
        } catch {
            Self.coderouterLogger.error("CodeRouter account refresh failed: \(error.localizedDescription, privacy: .public)")
            // A superseded refresh must not clear the destination its
            // replacement may already have stored.
            guard !Task.isCancelled,
                  accountFlow?.confirmedTeamID == teamID,
                  accountFlow?.currentIdentity?.id == identityID else { return }
            // Keep account rows visible during a transient failure, but never
            // let an old organization remain eligible for a new account.
            coderouterDestination = nil
        }
    }

    @MainActor
    private func removeCoderouterAccount(_ account: CloudTreeNode.CoderouterAccount) {
        guard let teamID = accountFlow?.confirmedTeamID else { return }
        let teamName = accountFlow?.availableTeams.first(where: { $0.id == teamID })?.displayName
        let knownOrganizationID = coderouterDestination?.teamID == teamID
            && coderouterDestination?.identityID == accountFlow?.currentIdentity?.id
            ? coderouterDestination?.organizationID
            : nil
        guard CloudTreeNodeActions.confirmDestructive(
            title: String(format: String(localized: "coderouter.removeAccount.title", defaultValue: "Remove “%@” from coderouter?"), account.title),
            message: String(localized: "coderouter.removeAccount.message", defaultValue: "The team stops routing agents through this account. You can add it again later."),
            verb: String(localized: "coderouter.removeAccount.verb", defaultValue: "Remove")
        ) else { return }
        // Reflect the user's action immediately. Keep the removed row around so
        // a failed request can restore the exact ordering returned by the last
        // successful read.
        let previousIndex = coderouter.accounts.firstIndex { $0.id == account.id } ?? coderouter.accounts.endIndex
        coderouter.accounts.removeAll { $0.id == account.id }
        Task { @MainActor in
            do {
                try await CoderouterCLIAccountReader.remove(
                    accountID: account.id,
                    for: teamID,
                    name: teamName,
                    knownOrganizationID: knownOrganizationID
                )
            } catch {
                Self.coderouterLogger.error("CodeRouter account removal failed: \(error.localizedDescription, privacy: .public)")
                // Do not restore an old team's account after a team switch.
                if accountFlow?.confirmedTeamID == teamID,
                   !coderouter.accounts.contains(where: { $0.id == account.id }) {
                    let index = min(previousIndex, coderouter.accounts.endIndex)
                    coderouter.accounts.insert(account, at: index)
                }
                viewModel.noteTreeFailure(error.localizedDescription)
            }
            requestCoderouterRefresh()
        }
    }

    /// Restarts the refresh loop now; the loop clears the spinner after its read.
    @MainActor
    private func requestCoderouterRefresh() {
        guard !coderouter.isRefreshing else { return }
        coderouterDestination = nil
        coderouter.isRefreshing = true
        coderouterRefreshRequest += 1
    }

    @MainActor
    private func addCoderouterAccount(_ provider: CoderouterProvider) {
        guard let teamID = accountFlow?.confirmedTeamID,
              !teamID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            viewModel.noteTreeHint(String(localized: "coderouter.selectTeam", defaultValue: "Select a team before adding a coding agent account."))
            return
        }
        guard let destination = coderouterDestination,
              destination.teamID == teamID,
              destination.identityID == accountFlow?.currentIdentity?.id else {
            viewModel.noteTreeHint(String(localized: "coderouter.loadingTeam", defaultValue: "CodeRouter is still loading this team's account settings. Try again in a moment."))
            requestCoderouterRefresh()
            return
        }
        // Pass the matched organization explicitly. The CodeRouter CLI config
        // is shared with terminals, so relying on its active organization can
        // send a new account to another team's pool during a concurrent switch.
        // A login shell can reorder PATH. Pin the same app whose bundled core
        // established supportsTeamOption instead of resolving another cmux.
        let cliPath = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/bin/cmux").path
        let command = provider.addCommand(
            for: destination.organizationID,
            supportsTeamOption: destination.supportsTeamOption,
            cmuxExecutable: cliPath
        )

        // Setup needs this Mac's credentials and an interactive shell. The
        // focused terminal might instead be remote or running an agent/editor.
        guard let workspaceID = tabManager?.selectedWorkspace?.id else {
            viewModel.noteTreeHint(String(localized: "coderouter.selectWorkspace", defaultValue: "Select a local workspace before adding a coding agent account."))
            return
        }
        Task { @MainActor in
            do {
                _ = try await TerminalController.surfaceNewTerminal(
                    machine: .local,
                    command: ["sh", "-lc", command],
                    cwd: nil,
                    name: "CodeRouter",
                    remoteWorkspaceID: nil,
                    destination: .workspace(id: workspaceID, placement: .split),
                    focus: true
                )
            } catch {
                viewModel.noteTreeFailure(error.localizedDescription)
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            if !includesCloud {
                Image(systemName: "desktopcomputer")
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(.secondary)
                Text(String(localized: "devices.empty.title", defaultValue: "No other devices yet"))
                    .font(.callout.weight(.medium))
                Text(String(localized: "devices.empty.help", defaultValue: "Sign in to cmux on another Mac and make it discoverable in Settings › Devices."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                Button(String(localized: "devices.settings", defaultValue: "Devices Settings…")) {
                    SettingsWindowPresenter.show(navigationTarget: .computers)
                }
            } else if let status = viewModel.listStatus {
                // Say the true thing instead of pretending the fleet is empty:
                // offline, reconnecting, or the failure with its real fix.
                MachinesListStatusEmptyState(status: status, perform: performListStatusAction)
            } else if isTeamChangePending {
                teamScopeLoading
            } else if viewModel.hasLoadedOnce {
                Image(systemName: "cloud")
                    .font(.system(size: 30, weight: .light))
                    .foregroundColor(.secondary.opacity(0.55))
                Text(String(localized: "machines.empty.title", defaultValue: "No machines yet"))
                    .cmuxFont(size: 13, weight: .semibold)
                    .foregroundColor(.primary.opacity(0.85))
                Text(String(
                    localized: "machines.empty.subtitle",
                    defaultValue: "A machine is a persistent cloud computer. It keeps your files forever and costs nothing while it sleeps."
                ))
                .cmuxFont(size: 12)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)
                Button {
                    requestNewMachine()
                } label: {
                    Text(String(localized: "machines.empty.create", defaultValue: "New Machine"))
                        .cmuxFont(size: 12)
                }
                .cloudProminentButtonStyle()
                .controlSize(.small)
                .padding(.top, 2)
                if let plan = viewModel.plan, !plan.isPaidPlan {
                    // The upgrade nudge under the create button: same Pro flow
                    // as the header count's at-limit tooltip and the ＋ at the ceiling.
                    Button {
                        ProUpgradePresenter.present(source: .machinesPanelUpgradeNudge)
                    } label: {
                        Text(upgradeNudgeLabel(plan))
                            .cmuxFont(size: 11)
                            .foregroundColor(.secondary.opacity(0.7))
                            .underline()
                    }
                    .buttonStyle(.plain)
                } else if let plan = viewModel.plan {
                    Text(planIncludesLabel(plan))
                        .cmuxFont(size: 11)
                        .foregroundColor(.secondary.opacity(0.7))
                }
            } else {
                ProgressView()
                    .controlSize(.small)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("CloudMachinesEmptyState")
        .cloudErrorCopyMenu(String(localized: "cloud.operation.failedAction", defaultValue: "This operation did not complete. Check the machine state before you try it again."))
    }

    /// Free plans: "Upgrade to use more than 1 machine" — the ceiling plus the
    /// way past it in one line. A plan with no machines at all has no ceiling
    /// to cite: upgrading is what grants access in the first place (the paid
    /// allowance itself is stated on /pricing, not guessed here).
    private func upgradeNudgeLabel(_ plan: MachinePlanSnapshot) -> String {
        guard let maxActiveVms = plan.maxActiveVms, maxActiveVms > 0 else {
            return String(
                localized: "machines.empty.upgrade.none",
                defaultValue: "Subscribe to cmux Pro to create Cloud machines"
            )
        }
        if plan.isSingleMachinePlan {
            return String(
                localized: "machines.empty.upgrade.single",
                defaultValue: "Upgrade to use more than 1 machine"
            )
        }
        return String(
            format: String(localized: "machines.empty.upgrade", defaultValue: "Upgrade to use more than %d machines"),
            maxActiveVms
        )
    }

    /// Paid plans: "Your plan includes 5 machines" under the create button,
    /// so the empty state answers "what do I get" before the Cloud Machines
    /// header shows a count. The uncapped wording only appears when an
    /// operator lifted the cap.
    private func planIncludesLabel(_ plan: MachinePlanSnapshot) -> String {
        guard let maxActiveVms = plan.maxActiveVms else {
            return String(
                localized: "machines.empty.planIncludes.unlimited",
                defaultValue: "Your plan includes unlimited machines"
            )
        }
        if plan.isSingleMachinePlan {
            return String(
                localized: "machines.empty.planIncludes.single",
                defaultValue: "Your plan includes 1 machine"
            )
        }
        return String(
            format: String(localized: "machines.empty.planIncludes", defaultValue: "Your plan includes %d machines"),
            maxActiveVms
        )
    }
}

/// Restarts the CodeRouter refresh loop when the team changes or a refresh is requested.
private struct CoderouterRefreshKey: Equatable {
    let teamID: String?
    let identityID: String?
    let request: Int
}
