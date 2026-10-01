import CmuxCloudBannerCore
import CmuxCloud
import AppKit
import CmuxCloudMachines
import CmuxSettings
import CmuxSurfaceCatalogModel
import SwiftUI

/// Right-sidebar Machines tab: the user's cloud machine fleet as a Finder-like
/// tree (machine → Workspaces → terminals, Ports, Displays, Terminals). Matches the
/// Vault/Feed visual language — compact 13pt rows, full-width hover
/// backgrounds, chrome-pill control bar. Outline rows receive immutable
/// snapshots plus closure bundles only (snapshot-boundary rule); every mutation
/// routes through the shared Cloud VM action path or the Cloud tree service.
struct MachinesPanelView: View {
    @StateObject var viewModel: MachinesPanelViewModel
    @State private var devicesModel: DevicesPanelViewModel
    @State private var discoveryManaged = ManagedDevicePolicy().isDeviceDiscoveryDisabled
    @State private var incomingAccessManaged = ManagedDevicePolicy().isIncomingDeviceAccessDisabled
    @AppStorage(RightSidebarBetaFeatureSettings.cloudMachinesEnabledKey)
    private var cloudBetaEnabled = RightSidebarBetaFeatureSettings.defaultCloudMachinesEnabled
    @State private var expansionStore = CloudTreeExpansionStore()
    /// The explicit Cloud VPN's state (`cmux vpn up`), shown as a banner while
    /// it is starting, waiting for the extension approval, up, or failed.
    @State private var tunnelStatus = CloudTunnelStatusModel()
    @State private var devBackend = DevBackendStartup()
    /// The main workspace selection is the authority for the tree projection.
    /// Keep this request window-local so another window cannot move this tree.
    @State private var selectionReveal: CloudTreeRevealRequest?
    @State private var bannerDismissals: CloudBannerDismissalStore
    /// The tree's visual preset; the debug gallery's "Use" buttons write this,
    /// and @AppStorage re-renders the live panel the moment it changes.
    @AppStorage(CloudTreeStyleStore.defaultsKey) private var cloudTreeStyleID: String = CloudTreeStyle.defaultStyle.id
    let chromeBackgroundColor: NSColor
    var tabManager: TabManager? = nil
    let teamPickerPresentation: CloudTeamPickerPresentation?

    init(
        chromeBackgroundColor: NSColor,
        viewModel: MachinesPanelViewModel? = nil,
        machinePinStore: CloudMachinePinStore? = nil,
        devicesModel: DevicesPanelViewModel? = nil,
        tabManager: TabManager? = nil,
        teamPickerPresentation: CloudTeamPickerPresentation? = nil
    ) {
        self.chromeBackgroundColor = chromeBackgroundColor
        self.tabManager = tabManager
        self.teamPickerPresentation = teamPickerPresentation
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

    private var accountFlow: HostAccountFlow? {
        AppDelegate.shared?.auth?.accountFlow
    }

    private var authState: CloudVMPanelAuthState {
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
        _ = cloudBetaEnabled
        return CloudMachinesFeature.isEnabled
    }

    /// The panel replaces its cached tree as soon as a team mutation starts;
    /// waiting for the scope observer would leave the previous team's rows
    /// visible while the create or switch is still in flight.
    private var isTeamChangePending: Bool {
        accountFlow?.isSelectingTeam == true
            || accountFlow?.isCreatingTeam == true
            || viewModel.awaitingCatalogScope
    }

    private var teamScopeLoadingLabel: String {
        if accountFlow?.isCreatingTeam == true {
            return String(localized: "cloud.teamPicker.creating", defaultValue: "Creating team…")
        }
        return String(localized: "cloud.teamPicker.switching", defaultValue: "Switching teams…")
    }

    private var treeSource: CloudTreeMachineSource { .cloudWithDevicesSection }

    private var selectedCloudIdentity: String? {
        guard let workspace = tabManager?.selectedWorkspace,
              let machineID = workspace.cloudVMID else { return nil }
        return [machineID, workspace.cloudVMBinding?.remoteWorkspaceID ?? ""].joined(separator: "\u{1f}")
    }

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
        VStack(spacing: 0) {
            switch authState {
            case .checking:
                authCheckingState
            case .signedOut:
                authGate
            case .signedIn:
                authenticatedContent
            }
        }
        .onAppear { syncPolling(for: authState) }
        .onAppear { refreshSelectionReveal() }
        .onChange(of: selectedCloudIdentity) { _, _ in refreshSelectionReveal() }
        .onChange(of: devicesModel.preferences?.discoveryEnabled) { _, _ in syncPolling(for: authState) }
        .onChange(of: cloudBetaEnabled) { _, _ in syncPolling(for: authState) }
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
            viewModel.refreshAccountScope()
        }
        .onChange(of: accountFlow?.currentIdentity?.id) { _, _ in
            viewModel.refreshAccountScope()
        }
        .onDisappear {
            viewModel.stopPolling()
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
        .task(id: devBackend.attempt) {
            await devBackend.observe()
            if devBackend.status?.isReady == true { viewModel.refresh() }
        }
        .accessibilityIdentifier("CloudMachinesPanel")
    }

    /// Project the selected workspace by stable machine/workspace identity.
    /// Names are intentionally absent: duplicate workspace names are valid.
    private func refreshSelectionReveal() {
        guard let workspace = tabManager?.selectedWorkspace,
              let machineID = workspace.cloudVMID else {
            selectionReveal = nil
            return
        }
        let machine = SurfaceMachineID.cloud(machineID)
        let nodeID: String
        if let remoteWorkspaceID = workspace.cloudVMBinding?.remoteWorkspaceID,
           !remoteWorkspaceID.isEmpty {
            nodeID = CloudTreeNodeBuilder.nodeID(workspace: remoteWorkspaceID, machine: machine)
        } else {
            nodeID = CloudTreeNodeBuilder.nodeID(machine: machine)
        }
        selectionReveal = CloudTreeRevealRequest(token: UUID(), nodeID: nodeID)
    }

    @ViewBuilder
    private var authenticatedContent: some View {
        if includesCloud {
            controlBar
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

    private var teamScopeLoading: some View {
        VStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            Text(teamScopeLoadingLabel)
                .cmuxFont(size: 12)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("CloudMachinesTeamLoading")
    }
    private func syncPolling(for state: CloudVMPanelAuthState) {
        switch state {
        case .signedIn:
            if includesCloud {
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

    /// The panel's complete header, including its persistent recovery status.
    var controlBar: some View {
        CloudTeamPickerHeader(
            accountFlow: accountFlow,
            presentation: teamPickerPresentation,
            chromeBackgroundColor: chromeBackgroundColor,
            isRefreshing: viewModel.isLoading || devicesModel.isRefreshing,
            onRefresh: refreshMachines,
            onNewMachine: requestNewMachine,
            agentMenu: { cloudAgentMenu },
            status: { cloudStatus }
        )
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

    private var authCheckingState: some View {
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
    private var authGate: some View {
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

    /// Cloud-agent launcher: each agent entry opens a local terminal running
    /// that agent preloaded with the cmux Cloud skill; Copy Cloud Prompt puts
    /// the same kickoff prompt on the clipboard for any other terminal.
    private var cloudAgentMenu: some View {
        Menu {
            ForEach(CloudAgentSkillLauncher.CodingAgent.allCases, id: \.rawValue) { agent in
                Button(agent.displayName) {
                    launchCloudAgent(agent)
                }
            }
            Divider()
            Button(String(localized: "machines.agent.copyPrompt", defaultValue: "Copy Cloud Prompt")) {
                runCloudAgentAction { try CloudAgentSkillLauncher.copyPrompt() }
            }
        } label: {
            Image(systemName: "sparkles")
                .font(.system(size: 11, weight: .medium))
                .frame(width: 22, height: 20)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 22, height: 20)
        .foregroundColor(.secondary)
        .help(String(localized: "machines.agent.menuLabel", defaultValue: "Open Cloud Agent"))
        .accessibilityLabel(String(localized: "machines.agent.menuLabel", defaultValue: "Open Cloud Agent"))
        .accessibilityIdentifier("CloudMachinesAgentMenu")
    }

    private func runCloudAgentAction(_ action: () throws -> Void) {
        do {
            try action()
        } catch {
            viewModel.noteTreeFailure(error.localizedDescription)
        }
    }

    private func launchCloudAgent(_ agent: CloudAgentSkillLauncher.CodingAgent) {
        viewModel.beginOperation(String(
            format: String(localized: "machines.agent.operation.starting", defaultValue: "Starting %@…"),
            agent.displayName
        ))
        Task { @MainActor [weak viewModel] in
            do {
                _ = try await CloudAgentSkillLauncher.openAgent(agent)
            } catch {
                viewModel?.noteTreeFailure(error.localizedDescription)
            }
            viewModel?.endOperation()
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
            }
        )
        // The list endpoint is authoritative for the caller's plan-sized
        // memory ladder. Feed it into the menu so Pro users do not select a
        // Max-only size and wait for a server rejection.
        let planMemoryGiB = viewModel.memoryOptionsMb.map { $0 / 1024 }.filter { $0 > 0 }
        machineActions.resizeMemoryOptionsGiB = planMemoryGiB
        machineActions.resizeCPUOptions = planMemoryGiB.map { max(1, ($0 + 3) / 4) }
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
                incomingAccessManaged: incomingAccessManaged, available: DevicesFeature.isAvailable()
            ),
            showsCloudVPNWarning: tunnelStatus.status?.state == .off,
            canCreateCloudMachine: includesCloud,
            cloudMachinesUsage: includesCloud ? viewModel.visibleUsage : nil,
            reveal: devicesModel.revealRequest ?? selectionReveal,
            creationReveal: SurfaceCatalog.shared.cloudWorkspaceCreationCoordinator.reveals.reveal(for: tabManager)
        )
        .accessibilityIdentifier("CloudMachinesTree")
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            if !includesCloud {
                Image(systemName: "desktopcomputer")
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(.secondary)
                Text(String(localized: "devices.empty.title", defaultValue: "No other Macs yet"))
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
            } else if viewModel.awaitingCatalogScope {
                VStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    Text(String(
                        localized: "cloud.teamPicker.switching",
                        defaultValue: "Switching teams…"
                    ))
                    .cmuxFont(size: 12)
                    .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("CloudMachinesTeamLoading")
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
                .buttonStyle(.borderedProminent)
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

    /// Paid plans: "Your plan includes 50 machines" under the create button,
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
