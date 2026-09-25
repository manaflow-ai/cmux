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
    @StateObject private var viewModel: MachinesPanelViewModel
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
    @State private var bannerDismissals = CloudBannerDismissalStore(defaults: .standard)
    /// The tree's visual preset; the debug gallery's "Use" buttons write this,
    /// and @AppStorage re-renders the live panel the moment it changes.
    @AppStorage(CloudTreeStyleStore.defaultsKey) private var cloudTreeStyleID: String = CloudTreeStyle.defaultStyle.id
    let chromeBackgroundColor: NSColor
    var tabManager: TabManager? = nil
    let teamPickerPresentation: CloudTeamPickerPresentation?

    init(
        chromeBackgroundColor: NSColor,
        machinePinStore: CloudMachinePinStore? = nil,
        devicesModel: DevicesPanelViewModel? = nil,
        tabManager: TabManager? = nil,
        teamPickerPresentation: CloudTeamPickerPresentation? = nil
    ) {
        self.chromeBackgroundColor = chromeBackgroundColor
        self.tabManager = tabManager
        self.teamPickerPresentation = teamPickerPresentation
        _viewModel = StateObject(wrappedValue: MachinesPanelViewModel(
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

    private var treeSource: CloudTreeMachineSource {
        .cloudWithDevicesSection
    }

    private var treeSnapshot: SurfaceCatalogSnapshot {
        viewModel.catalog.applyingDeviceVisibility(
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
        } else {
            content
        }
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
            activeOperation: viewModel.activeOperation,
            staleError: viewModel.machines.isEmpty ? nil : viewModel.lastErrorDescription.flatMap {
                bannerDismissals.isDismissed(id: "machines.stale", signature: $0) ? nil : $0
            },
            treeError: viewModel.treeErrorDescription,
            plan: viewModel.plan,
            onDismissStale: { bannerDismissals.dismiss(id: "machines.stale", signature: $0) }
        )
    }

    private var controlBar: some View {
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
        if includesCloud && includesDevices && viewModel.hasLoadedOnce && viewModel.machines.isEmpty && viewModel.lastErrorDescription != nil {
            VStack(spacing: 0) {
                cloudMachinesUnavailableNotice
                machinesList
            }
        } else if CloudTreeNodeBuilder.isEmpty(
            machines: includesCloud ? viewModel.machines : [],
            pendingCreates: includesCloud ? viewModel.pendingCreates : [],
            snapshot: treeSnapshot,
            source: treeSource
        ) {
            emptyState
        } else {
            machinesList
        }
    }

    @ViewBuilder
    private var cloudMachinesUnavailableNotice: some View {
        switch viewModel.listProblem ?? .unreachable {
        case .sessionRejected:
            cloudMachinesNotice(
                symbolName: "person.crop.circle.badge.exclamationmark",
                title: String(localized: "machines.sessionRejected.title", defaultValue: "Sign-in needs a refresh"),
                actionTitle: String(localized: "machines.sessionRejected.signInAgain", defaultValue: "Sign Out & Sign In Again"),
                actionIdentifier: "CloudMachinesSessionRejectedSignInButton",
                action: signOutForFreshSignIn
            )
        case .requiresPro:
            cloudMachinesNotice(
                symbolName: "sparkles",
                title: String(localized: "machines.requiresPro.title", defaultValue: "Cloud machines need cmux Pro"),
                actionTitle: String(localized: "machines.requiresPro.upgrade", defaultValue: "Upgrade to Pro"),
                actionIdentifier: "CloudMachinesRequiresProUpgradeButton"
            ) {
                ProUpgradePresenter.present(source: .machinesPanelRequiresPro)
            }
        case .unreachable:
            cloudMachinesNotice(
                symbolName: "cloud.slash",
                title: String(localized: "machines.unavailable.title", defaultValue: "Cloud is unreachable"),
                actionTitle: String(localized: "machines.unavailable.retry", defaultValue: "Retry"),
                actionIdentifier: "CloudMachinesUnavailableRetryButton"
            ) {
                viewModel.refresh()
            }
        }
    }

    private func cloudMachinesNotice(
        symbolName: String,
        title: String,
        actionTitle: String,
        actionIdentifier: String,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbolName)
                .font(.system(size: 11, weight: .semibold))
            Text(title)
                .cmuxFont(size: 11)
                .lineLimit(1)
            Spacer(minLength: 4)
            Button(actionTitle, action: action)
                .buttonStyle(.link)
                .cmuxFont(size: 11)
                .accessibilityIdentifier(actionIdentifier)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.orange.opacity(0.08))
        .accessibilityIdentifier("CloudMachinesUnavailableNotice")
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

    @ViewBuilder
    private var unreachableState: some View {
        Image(systemName: "cloud.slash")
            .font(.system(size: 26, weight: .light))
            .foregroundColor(.secondary.opacity(0.55))
        Text(String(localized: "machines.unavailable.title", defaultValue: "Cloud is unreachable"))
            .cmuxFont(size: 13)
            .foregroundColor(.primary.opacity(0.85))
        Text(String(
            localized: "machines.unavailable.subtitle",
            defaultValue: "Your machines are still there. cmux couldn’t reach the Cloud service just now; it retries on its own."
        ))
        .cmuxFont(size: 12)
        .foregroundColor(.secondary)
        .multilineTextAlignment(.center)
        .padding(.horizontal, 24)
        Button {
            viewModel.refresh()
        } label: {
            Text(String(localized: "machines.unavailable.retry", defaultValue: "Retry"))
                .cmuxFont(size: 12)
        }
        .padding(.top, 2)
    }

    /// HTTP 401 from the Cloud service while the app still holds a session:
    /// retrying can never fix it, so route straight to a fresh sign-in.
    @ViewBuilder
    private var sessionRejectedState: some View {
        Image(systemName: "person.crop.circle.badge.exclamationmark")
            .font(.system(size: 26, weight: .light))
            .foregroundColor(.secondary.opacity(0.55))
        Text(String(localized: "machines.sessionRejected.title", defaultValue: "Sign-in needs a refresh"))
            .cmuxFont(size: 13, weight: .semibold)
            .foregroundColor(.primary.opacity(0.85))
        Text(String(
            localized: "machines.sessionRejected.subtitle",
            defaultValue: "The Cloud service no longer accepts this Mac’s saved session. Sign out and sign back in to reconnect."
        ))
        .cmuxFont(size: 12)
        .foregroundColor(.secondary)
        .multilineTextAlignment(.center)
        .padding(.horizontal, 24)
        Button {
            signOutForFreshSignIn()
        } label: {
            Text(String(localized: "machines.sessionRejected.signInAgain", defaultValue: "Sign Out & Sign In Again"))
                .cmuxFont(size: 12)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.small)
        .padding(.top, 2)
        .accessibilityIdentifier("CloudMachinesSessionRejectedSignInButton")
    }

    /// HTTP 402: the plan gates Cloud access, so the fix is an upgrade, not a
    /// retry and not a sign-in.
    @ViewBuilder
    private var requiresProState: some View {
        Image(systemName: "sparkles")
            .font(.system(size: 26, weight: .light))
            .foregroundColor(.secondary.opacity(0.55))
        Text(String(localized: "machines.requiresPro.title", defaultValue: "Cloud machines need cmux Pro"))
            .cmuxFont(size: 13, weight: .semibold)
            .foregroundColor(.primary.opacity(0.85))
        Text(String(
            localized: "machines.requiresPro.subtitle",
            defaultValue: "This account’s plan doesn’t include Cloud machine access. Upgrade to create and reconnect machines."
        ))
        .cmuxFont(size: 12)
        .foregroundColor(.secondary)
        .multilineTextAlignment(.center)
        .padding(.horizontal, 24)
        Button {
            ProUpgradePresenter.present(source: .machinesPanelRequiresPro)
        } label: {
            Text(String(localized: "machines.requiresPro.upgrade", defaultValue: "Upgrade to Pro"))
                .cmuxFont(size: 12)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.small)
        .padding(.top, 2)
        .accessibilityIdentifier("CloudMachinesRequiresProUpgradeButton")
    }

    /// Server-rejected sessions can only be fixed by re-authenticating; the
    /// sign-out flips the pane to the sign-in gate, whose flow mints a fresh
    /// session.
    private func signOutForFreshSignIn() {
        guard let accountFlow else { return }
        Task { await accountFlow.signOut() }
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

    /// ＋ on a free plan at its ceiling is the upgrade moment: open the Pro flow
    /// instead of launching a create that the backend would only paywall.
    /// Otherwise the New Machine sheet collects the size; its Create runs the
    /// same `cmux vm new` path the CLI and palette use, and shows up here as a
    /// pending row (`viewModel.pendingCreates`), not as panel chrome.
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
            onWillMutate: { [weak viewModel] label in viewModel?.beginOperation(label) },
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
            onWillMutate: { [weak viewModel] label in viewModel?.beginOperation(label) },
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
        return CloudTreeOutlineView(
            machines: includesCloud ? viewModel.sidebarMachines : [],
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
                incomingAccessManaged: incomingAccessManaged
            ), showsCloudVPNWarning: tunnelStatus.status?.state == .off,
            reveal: devicesModel.revealRequest
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
                Text(String(localized: "devices.empty.help", defaultValue: "Sign in to cmux on another Mac and make it discoverable in Settings › Mobile › Computers."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                Button(String(localized: "devices.settings", defaultValue: "Computers Settings…")) {
                    SettingsWindowPresenter.show(navigationTarget: .computers)
                }
            } else if viewModel.hasLoadedOnce, viewModel.lastErrorDescription != nil {
                // The list failed to load: say the true thing instead of
                // pretending the fleet is empty. A server-rejected session and
                // a plan gate each get their real fix; only transient-shaped
                // failures keep the retry-first "unreachable" copy.
                switch viewModel.listProblem ?? .unreachable {
                case .sessionRejected:
                    sessionRejectedState
                case .requiresPro:
                    requiresProState
                case .unreachable:
                    unreachableState
                }
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
                    // as the meter's at-limit hint and the ＋ at the ceiling.
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
        .cloudErrorCopyMenu(viewModel.lastErrorDescription)
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
    /// so the empty state answers "what do I get" before the meter shows a
    /// count. The uncapped wording only appears when an operator lifted the
    /// cap.
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
