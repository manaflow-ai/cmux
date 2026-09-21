import CmuxCloudMachines
import AppKit
import CmuxSettings
import SwiftUI

enum CloudVMPanelAuthState: Equatable {
    case checking
    case signedOut
    case signedIn

    static func resolve(isAuthenticated: Bool, isWorkingOnAuth: Bool) -> Self {
        if isAuthenticated { return .signedIn }
        if isWorkingOnAuth { return .checking }
        return .signedOut
    }

    /// Whether a native Cloud VM operation may start in this state.
    var allowsAuthenticatedOperation: Bool {
        self == .signedIn
    }
}

struct MachinesPanelView: View {
    @StateObject private var viewModel: MachinesPanelViewModel
    @State private var expansionStore = CloudTreeExpansionStore()
    @State private var tunnelStatus = CloudTunnelStatusModel()
    @State private var devBackend = DevBackendStartup()
    @AppStorage(CloudTreeStyleStore.defaultsKey) private var cloudTreeStyleID: String = CloudTreeStyle.defaultStyle.id
#if DEBUG
    @Environment(\.cloudSidebarDebugSettings) private var cloudSidebarDebugSettings
#endif
    @State private var bannerDismissals = CloudBannerDismissalStore(defaults: .standard)
    let chromeBackgroundColor: NSColor
    var tabManager: TabManager? = nil


    init(
        chromeBackgroundColor: NSColor,
        machinePinStore: CloudMachinePinStore? = nil,
        tabManager: TabManager? = nil
    ) {
        self.chromeBackgroundColor = chromeBackgroundColor
        self.tabManager = tabManager
        _viewModel = StateObject(wrappedValue: MachinesPanelViewModel(
            machinePinStore: machinePinStore,
            localWorkspacesProvider: { [weak tabManager] in
                guard let tabManager else { return [] }
                return tabManager.tabs.map {
                    CloudTreeLocalWorkspace(id: $0.id, title: $0.title, isSelected: $0.id == tabManager.selectedTabId)
                }
            }
        ))
    }

    private var accountFlow: HostAccountFlow? {
        AppDelegate.shared?.auth?.accountFlow
    }

    private var authState: CloudVMPanelAuthState {
        CloudVMPanelAuthState.resolve(
            isAuthenticated: accountFlow?.isAuthenticated == true,
            isWorkingOnAuth: accountFlow?.isCompletingSignIn == true
        )
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
        controlBar
        MachinesPanelBanners(
            tunnelBanner: tunnelStatus.banner, plan: viewModel.plan,
            bannerDismissals: bannerDismissals, chromeBackgroundColor: chromeBackgroundColor
        )
        if let status = devBackend.status, !status.isReady {
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
            viewModel.startPolling()
        case .checking, .signedOut:
            viewModel.stopPolling()
            viewModel.resetForAuthTransition()
        }
    }

    private var controlBar: some View {
        HStack(spacing: 6) {
            Group {
                if let operation = viewModel.activeOperation {
                    HStack(spacing: 5) {
                        ProgressView()
                            .controlSize(.mini)
                        Text(operation)
                            .cmuxFont(size: 11)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                } else if let error = viewModel.lastErrorDescription, !viewModel.machines.isEmpty,
                          !bannerDismissals.isDismissed(id: "machines.stale", signature: error) {
                    HStack(spacing: 5) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 10, weight: .semibold))
                        Text(String(localized: "machines.unavailable.stale", defaultValue: "Cloud unreachable — showing last known"))
                            .cmuxFont(size: 11)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .foregroundColor(.orange.opacity(0.9))
                    .help(viewModel.lastErrorDescription ?? "")
                    .cloudErrorCopyMenu(viewModel.lastErrorDescription)
                    CloudBannerDismissButton {
                        bannerDismissals.dismiss(id: "machines.stale", signature: error)
                    }
                } else if let treeError = viewModel.treeErrorDescription {
                    // The message itself, not a generic label: a failed tree verb (New
                    // Terminal Here, Open Shell, …) otherwise reads as a dead menu item,
                    // with the only explanation hidden behind a hover tooltip.
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 10, weight: .semibold))
                        Text(treeError)
                            .cmuxFont(size: 11)
                            .lineLimit(2)
                            .truncationMode(.tail)
                    }
                    .foregroundColor(.orange.opacity(0.9))
                    .help(treeError)
                    .cloudErrorCopyMenu(treeError)
                } else if let plan = viewModel.plan {
                    MachinePlanMeter(plan: plan)
                }
            }
            // Bar leading is 8pt; +4 puts the leading text at 12pt — the same
            // column as the mode-bar pill glyphs (4pt bar + 8pt pill inset)
            // and the Files header icon.
            .padding(.leading, 4)
            Spacer(minLength: 4)
            cloudAgentMenu
            MachinesChromeIconButton(
                symbolName: "arrow.clockwise",
                accessibilityLabel: String(localized: "machines.refresh", defaultValue: "Refresh Machines"),
                isBusy: viewModel.isLoading
            ) {
                viewModel.refresh(tree: true)
            }
            MachinesChromeIconButton(
                symbolName: "plus",
                accessibilityLabel: String(localized: "machines.new", defaultValue: "New Machine"),
                isBusy: false
            ) {
                requestNewMachine()
            }
        }
        .rightSidebarChromeBar()
        .rightSidebarChromeBottomBorder(backgroundColor: chromeBackgroundColor)
    }

    @ViewBuilder
    private var content: some View {
        // Show the empty state exactly when the outline would render zero
        // rows. The builder owns that decision (the tree is cloud-only while
        // `includesLocalMachine` is off); deciding it here from the raw
        // catalog previously left a blank panel for a signed-in account with
        // no machines, because the catalog's This Mac entry counted as a row
        // the tree never drew.
        if CloudTreeNodeBuilder.isEmpty(machines: viewModel.machines, pendingCreates: viewModel.pendingCreates, snapshot: viewModel.catalog) {
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
    private var resolvedTreeStyle: CloudTreeStyle {
        let base = CloudTreeStyle.preset(id: cloudTreeStyleID) ?? .defaultStyle
#if DEBUG
        return cloudSidebarDebugSettings?.metrics.resolvedStyle(base) ?? base
#else
        return base
#endif
    }

    /// Builds the snapshot-bound Cloud tree and binds its row actions.
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
        let nodeActions = CloudTreeNodeActions.bound(
            navigationHost: AppDelegate.makeCloudTerminalNavigationHost(),
            catalog: { SurfaceCatalog.shared },
            selectedWorkspaceID: { tabManager?.selectedTabId },
            selectLocalWorkspace: { workspaceID in
                tabManager?.selectedTabId = workspaceID
            },
            onWillMutate: { [weak viewModel] label in viewModel?.beginOperation(label) },
            onDidMutate: { [weak viewModel] in viewModel?.endOperation() },
            onFailure: { [weak viewModel] description in viewModel?.noteTreeFailure(description) },
            refresh: { [weak viewModel] in viewModel?.refresh(tree: true) }, refreshMachine: { [weak viewModel] in viewModel?.refreshMachine($0) },
            workspaceCreationHost: { tabManager.map { CloudWorkspaceCreationHost(manager: $0) } }
        )
        return CloudTreeOutlineView(
            machines: viewModel.sidebarMachines,
            pendingCreates: viewModel.pendingCreates, adoptedOperationIDs: viewModel.adoptedOperationIDs,
            snapshot: viewModel.catalog,
            localWorkspaces: viewModel.localWorkspaces,
            unreadTerminalIDs: viewModel.unreadTerminalIDs,
            machineActions: machineActions,
            nodeActions: nodeActions,
            expansionStore: expansionStore, organizationStore: SurfaceCatalog.shared.sidebarOrganization, organizationState: SurfaceCatalog.shared.sidebarOrganization.state,
            style: resolvedTreeStyle,
            onDragStateChange: { [weak viewModel] dragging in viewModel?.setTreeDragging(dragging) }
        )
        .accessibilityIdentifier("CloudMachinesTree")
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            if viewModel.hasLoadedOnce, viewModel.lastErrorDescription != nil {
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


/// "2 of 3" plan meter. Turns into the upgrade hint when a free plan hits its
/// machine ceiling — the moment of intent, and the only place we mention it.
private struct MachinePlanMeter: View {
    let plan: MachinePlanSnapshot

    var body: some View {
        HStack(spacing: 5) {
            Text(meterText)
                .cmuxFont(size: 11, monospacedDigit: true)
                .foregroundColor(plan.isAtLimit ? Color.orange : .secondary)
            if plan.isAtLimit && !plan.isPaidPlan {
                Text(String(localized: "machines.meter.upgrade", defaultValue: "Upgrade for more"))
                    .cmuxFont(size: 11)
                    .foregroundColor(.orange)
            }
        }
        .help(meterHelp)
        .accessibilityElement(children: .combine)
    }

    private var meterText: String { plan.countLabel }

    private var meterHelp: String {
        if plan.isAtLimit && !plan.isPaidPlan, let maxActiveVms = plan.maxActiveVms {
            if plan.isSingleMachinePlan {
                return String(
                    localized: "machines.meter.help.atLimit.single",
                    defaultValue: "Your plan includes 1 machine. Upgrade to create more."
                )
            }
            return String(
                localized: "machines.meter.help.atLimit",
                defaultValue: "Your plan includes %d machines. Upgrade to create more."
            ).replacingOccurrences(of: "%d", with: String(maxActiveVms))
        }
        return String(
            localized: "machines.meter.help",
            defaultValue: "Machines on your plan. Sleeping machines cost nothing."
        )
    }
}

struct MachinesFreeAccessBanner: View {
    let text: String
    let isExpired: Bool
    let windowDays: Int
    let backgroundColor: NSColor
    let onDismiss: () -> Void
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 5) {
            Button {
                ProUpgradePresenter.present(source: .machinesPanelTrialBanner)
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: isExpired ? "lock.fill" : "clock")
                        .font(.system(size: 10, weight: .semibold))
                    Text(text)
                        .cmuxFont(size: 11, monospacedDigit: true)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                    Text(String(localized: "machines.freeAccess.upgrade", defaultValue: "Upgrade"))
                        .cmuxFont(size: 11)
                        .underline(isHovered)
                }
            }
            .buttonStyle(.plain)
            .foregroundColor(isExpired ? Color.orange : .secondary)
            .accessibilityLabel(text)
            .layoutPriority(1)
            CloudBannerDismissButton(action: onDismiss)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .foregroundColor(isExpired ? Color.orange : .secondary)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .background(Color(nsColor: backgroundColor))
        .help(helpText)
        .accessibilityIdentifier("CloudMachinesFreeAccessBanner")
    }

    private var helpText: String {
        String(
            format: String(
                localized: "machines.freeAccess.help",
                defaultValue: "Free plans keep a machine reachable for %d days after it is created. Upgrade to Pro to keep using it."
            ),
            windowDays
        )
    }
}

struct MachinesChromeIconButton: View {
    let symbolName: String
    let accessibilityLabel: String
    let isBusy: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Group {
                if isBusy {
                    ProgressView()
                        .controlSize(.mini)
                } else {
                    CmuxSystemSymbolImage(magnified: symbolName, pointSize: 11, weight: .medium, tint: isHovered ? .primary : .secondary)
                }
            }
            .frame(width: 22, height: 20)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundColor(isHovered ? .primary : .secondary)
        .background(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(isHovered ? Color.primary.opacity(0.06) : Color.clear)
        )
        .onHover { isHovered = $0 }
        .help(accessibilityLabel)
        .accessibilityLabel(accessibilityLabel)
    }
}
