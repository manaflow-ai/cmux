import AppKit
import CmuxSettings
import SwiftUI

/// The local auth states that matter to the Cloud Machines panel. Keeping the
/// projection here means the panel never has to infer auth from a failed VM
/// request (which could otherwise briefly leave stale machine rows visible).
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

/// Right-sidebar Machines tab: the user's cloud machine fleet as a Finder-like
/// tree (machine → cmux-tui workspaces → terminals, desktop, ports). Matches the
/// Vault/Feed visual language — compact 13pt rows, full-width hover
/// backgrounds, chrome-pill control bar. Outline rows receive immutable
/// snapshots plus closure bundles only (snapshot-boundary rule); every mutation
/// routes through the shared Cloud VM action path or the Cloud tree service.
struct MachinesPanelView: View {
    @StateObject private var viewModel = MachinesPanelViewModel()
    @State private var expansionStore = CloudTreeExpansionStore()
    /// The tree's visual preset; the debug gallery's "Use" buttons write this,
    /// and @AppStorage re-renders the live panel the moment it changes.
    @AppStorage(CloudTreeStyleStore.defaultsKey) private var cloudTreeStyleID: String = CloudTreeStyle.defaultStyle.id
    let chromeBackgroundColor: NSColor

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
        }
        .onDisappear {
            viewModel.stopPolling()
        }
        .accessibilityIdentifier("CloudMachinesPanel")
    }

    @ViewBuilder
    private var authenticatedContent: some View {
        controlBar
        if let plan = viewModel.plan, !plan.isPaidPlan, let text = plan.freeAccessBannerText {
            MachinesFreeAccessBanner(
                text: text,
                isExpired: plan.freeAccessBanner == .expired,
                windowDays: plan.freeAccessWindowDays,
                backgroundColor: chromeBackgroundColor
            )
        }
        content
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
                } else if viewModel.lastErrorDescription != nil, !viewModel.machines.isEmpty {
                    HStack(spacing: 5) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 10, weight: .semibold))
                        Text(String(localized: "machines.unavailable.stale", defaultValue: "Cloud unreachable \u{2014} showing last known"))
                            .cmuxFont(size: 11)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .foregroundColor(.orange.opacity(0.9))
                    .help(viewModel.lastErrorDescription ?? "")
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
        if CloudTreeNodeBuilder.isEmpty(machines: viewModel.machines, snapshot: viewModel.catalog) {
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
            VStack(spacing: 8) {
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
                .padding(.horizontal, 20)
                AccountSignInView(model: signInModel, automaticallyStartsSignIn: false)
                    .frame(maxWidth: 440)
            }
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
            format: String(localized: "machines.agent.operation.starting", defaultValue: "Starting %@\u{2026}"),
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
    /// Otherwise the New Machine sheet collects name, kind, and size, and its
    /// Create runs the same `cmux vm new` path the CLI and palette use.
    private func requestNewMachine() {
        NewMachineSheetPresenter.shared.presentNewMachine(
            plan: viewModel.plan,
            imageKinds: viewModel.imageKinds,
            preferredWindow: NSApp.keyWindow ?? NSApp.mainWindow,
            operationDidBegin: { [weak viewModel] in
                viewModel?.beginOperation(String(localized: "machines.operation.create", defaultValue: "Creating a new machine\u{2026}"))
            },
            operationDidEnd: { [weak viewModel] in
                viewModel?.endOperation()
            }
        )
    }

    /// The Finder-like tree over the surface catalog: This Mac, then every
    /// machine, with their workspaces, terminals, screens, browsers, and ports
    /// underneath. Both closure bundles are bound here, above the outline; rows
    /// never see the store.
    private var machinesList: some View {
        let machineActions = MachineRowActions.bound(
            onWillMutate: { [weak viewModel] label in viewModel?.beginOperation(label) },
            onDidMutate: { [weak viewModel] in viewModel?.endOperation() }
        )
        let nodeActions = CloudTreeNodeActions.bound(
            catalog: { SurfaceCatalog.shared },
            selectedWorkspaceID: { AppDelegate.shared?.tabManager?.selectedTabId },
            selectLocalWorkspace: { workspaceID in
                AppDelegate.shared?.tabManager?.selectedTabId = workspaceID
            },
            onWillMutate: { [weak viewModel] label in viewModel?.beginOperation(label) },
            onDidMutate: { [weak viewModel] in viewModel?.endOperation() },
            onFailure: { [weak viewModel] description in viewModel?.noteTreeFailure(description) },
            refresh: { [weak viewModel] in viewModel?.refresh(tree: true) }
        )
        return CloudTreeOutlineView(
            machines: viewModel.machines,
            snapshot: viewModel.catalog,
            localWorkspaces: viewModel.localWorkspaces,
            machineActions: machineActions,
            nodeActions: nodeActions,
            expansionStore: expansionStore,
            style: CloudTreeStyle.preset(id: cloudTreeStyleID) ?? .defaultStyle,
            onDragStateChange: { [weak viewModel] dragging in viewModel?.setTreeDragging(dragging) }
        )
        .accessibilityIdentifier("CloudMachinesTree")
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            if viewModel.hasLoadedOnce, viewModel.lastErrorDescription != nil {
                // The list failed to load: say so instead of pretending the fleet is
                // empty, and make retry one click.
                Image(systemName: "cloud.slash")
                    .font(.system(size: 26, weight: .light))
                    .foregroundColor(.secondary.opacity(0.55))
                Text(String(localized: "machines.unavailable.title", defaultValue: "Cloud is unreachable"))
                    .cmuxFont(size: 13)
                    .foregroundColor(.primary.opacity(0.85))
                Text(String(
                    localized: "machines.unavailable.subtitle",
                    defaultValue: "Your machines are still there. cmux couldn\u{2019}t reach the Cloud service just now; it retries on its own."
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
                        ProUpgradePresenter.present()
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
    /// to cite: upgrading is what grants access in the first place.
    private func upgradeNudgeLabel(_ plan: MachinePlanSnapshot) -> String {
        if plan.maxActiveVms <= 0 {
            return String(
                localized: "machines.empty.upgrade.none",
                defaultValue: "Subscribe to cmux Pro to use up to 5 machines"
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
            plan.maxActiveVms
        )
    }

    /// Paid plans: "Your plan includes 5 machines" under the create button, so
    /// the empty state answers "what do I get" before the meter shows a count.
    private func planIncludesLabel(_ plan: MachinePlanSnapshot) -> String {
        if plan.isSingleMachinePlan {
            return String(
                localized: "machines.empty.planIncludes.single",
                defaultValue: "Your plan includes 1 machine"
            )
        }
        return String(
            format: String(localized: "machines.empty.planIncludes", defaultValue: "Your plan includes %d machines"),
            plan.maxActiveVms
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
        if plan.isAtLimit && !plan.isPaidPlan {
            if plan.isSingleMachinePlan {
                return String(
                    localized: "machines.meter.help.atLimit.single",
                    defaultValue: "Your plan includes 1 machine. Upgrade to create more."
                )
            }
            return String(
                localized: "machines.meter.help.atLimit",
                defaultValue: "Your plan includes %d machines. Upgrade to create more."
            ).replacingOccurrences(of: "%d", with: String(plan.maxActiveVms))
        }
        return String(
            localized: "machines.meter.help",
            defaultValue: "Machines on your plan. Sleeping machines cost nothing."
        )
    }
}

/// One line under the header on free plans: how long the fleet stays
/// reachable, counting down to the earliest machine's expiry, and the way out
/// (the whole line is the upgrade affordance — the same Pro flow the ＋ button
/// opens at the machine ceiling).
private struct MachinesFreeAccessBanner: View {
    let text: String
    let isExpired: Bool
    let windowDays: Int
    let backgroundColor: NSColor
    @State private var isHovered = false

    var body: some View {
        Button {
            ProUpgradePresenter.present()
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
            .foregroundColor(isExpired ? Color.orange : .secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .background(Color(nsColor: backgroundColor))
        .help(helpText)
        .accessibilityLabel(text)
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
                    Image(systemName: symbolName)
                        .font(.system(size: 11, weight: .medium))
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

/// Closure bundle handed to rows. Bound above the lazy boundary; rows never
/// see the store. All verbs go through `CloudVMActionLauncher` so this panel,
/// the ＋ menu, the palette, and the CLI share one mutation path.
struct MachineRowActions {
    let openShell: @MainActor (String) -> Void
    let openDesktop: @MainActor (String) -> Void
    let runCommand: @MainActor (String, [String]) -> Void
    let confirmDelete: @MainActor (String) -> Void
    let promptRename: @MainActor (String, String?) -> Void
    /// A locked (free-window-expired) machine routes here instead of a doomed
    /// connect; the backend enforces the same boundary with 402s.
    let promptUpgrade: @MainActor () -> Void

    static func bound(
        onWillMutate: @escaping @MainActor (String) -> Void = { _ in },
        onDidMutate: @escaping @MainActor () -> Void
    ) -> MachineRowActions {
        MachineRowActions(
            openShell: { id in
                onWillMutate(String(format: String(localized: "machines.operation.openShell", defaultValue: "Opening %@\u{2026}"), id))
                if !launch(arguments: ["vm", "shell", id], onDidMutate: onDidMutate) {
                    onDidMutate()
                }
            },
            openDesktop: { id in
                onWillMutate(String(format: String(localized: "machines.operation.openDesktop", defaultValue: "Opening %@\u{2019}s desktop\u{2026}"), id))
                if !launch(arguments: ["vm", "desktop", id], onDidMutate: onDidMutate) {
                    onDidMutate()
                }
            },
            runCommand: { id, verb in
                onWillMutate(operationLabel(verb: verb, id: id))
                let result = resultPresentation(verb: verb)
                if !launch(
                    arguments: verb + [id],
                    successTitle: result.title,
                    presentOutputOnSuccess: result.presentsOutput,
                    onDidMutate: onDidMutate
                ) {
                    onDidMutate()
                }
            },
            confirmDelete: { id in
                presentDeleteConfirmation(id: id, onWillMutate: onWillMutate, onDidMutate: onDidMutate)
            },
            promptRename: { id, currentLabel in
                presentRenamePrompt(id: id, currentLabel: currentLabel, onWillMutate: onWillMutate, onDidMutate: onDidMutate)
            },
            promptUpgrade: {
                ProUpgradePresenter.present()
            }
        )
    }

    /// What to show when a row verb finishes. Status and Checkpoint are
    /// read-only reports, so their output is the whole point and opens in the
    /// house result sheet; Fork attaches the new machine as a workspace, so a
    /// sheet would only get in the way. Same policy as the palette's
    /// `CurrentCloudVMCommand`.
    private static func resultPresentation(verb: [String]) -> (title: String?, presentsOutput: Bool) {
        if verb.contains("status") {
            return (String(localized: "command.cloudVM.status.result.title", defaultValue: "Cloud VM Status"), true)
        }
        if verb.contains("snapshot") {
            return (String(localized: "command.cloudVM.snapshot.result.title", defaultValue: "Cloud VM Checkpoint"), true)
        }
        if verb.contains("fork") {
            return (String(localized: "command.cloudVM.fork.result.title", defaultValue: "Cloud VM Forked"), false)
        }
        return (nil, false)
    }

    private static func operationLabel(verb: [String], id: String) -> String {
        let format: String
        if verb.contains("snapshot") {
            format = String(localized: "machines.operation.checkpoint", defaultValue: "Checkpointing %@\u{2026}")
        } else if verb.contains("fork") {
            format = String(localized: "machines.operation.fork", defaultValue: "Forking %@\u{2026}")
        } else if verb.contains("status") {
            format = String(localized: "machines.operation.status", defaultValue: "Checking %@\u{2026}")
        } else if verb.contains("rename") {
            format = String(localized: "machines.operation.rename", defaultValue: "Renaming %@\u{2026}")
        } else if verb.contains("rm") {
            format = String(localized: "machines.operation.delete", defaultValue: "Deleting %@\u{2026}")
        } else {
            format = String(localized: "machines.operation.generic", defaultValue: "Working on %@\u{2026}")
        }
        return String(format: format, id)
    }

    @MainActor
    @discardableResult
    /// `arguments` is the `cmux vm new …` invocation the New Machine sheet
    /// built (kind, size, name). Failures come back through `onCompletion`
    /// so the sheet can show them inline instead of a detached alert.
    static func openNewMachine(
        arguments: [String] = ["vm", "new"],
        onCompletion: ((CloudVMActionLauncher.Completion) -> Void)? = nil
    ) -> Bool {
        // `vm new` mints a fresh machine with its own persistent home and
        // attaches it; the base slot stays reachable via the ＋ menu's Open Base.
        let socketPath = TerminalController.shared.activeSocketPath(
            preferredPath: SocketControlSettings.socketPath()
        )
        return CloudVMActionLauncher.shared.start(
            socketPath: socketPath,
            preferredWindow: NSApp.keyWindow ?? NSApp.mainWindow,
            arguments: arguments,
            presentsFailureAlert: false,
            onCompletion: onCompletion
        )
    }

    @MainActor
    private static func launch(
        arguments: [String],
        successTitle: String? = nil,
        presentOutputOnSuccess: Bool = false,
        onSuccess: (@MainActor () -> Void)? = nil,
        onDidMutate: @escaping @MainActor () -> Void
    ) -> Bool {
        let socketPath = TerminalController.shared.activeSocketPath(
            preferredPath: SocketControlSettings.socketPath()
        )
        return CloudVMActionLauncher.shared.start(
            socketPath: socketPath,
            preferredWindow: NSApp.keyWindow ?? NSApp.mainWindow,
            arguments: arguments,
            successTitle: successTitle,
            presentOutputOnSuccess: presentOutputOnSuccess
        ) { completion in
            if completion.terminationStatus == 0 {
                onSuccess?()
            }
            onDidMutate()
        }
    }

    @MainActor
    private static func presentRenamePrompt(
        id: String,
        currentLabel: String?,
        onWillMutate: @escaping @MainActor (String) -> Void = { _ in },
        onDidMutate: @escaping @MainActor () -> Void
    ) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        let format = String(localized: "machines.rename.title", defaultValue: "Rename \u{201C}%@\u{201D}")
        alert.messageText = String(format: format, id)
        alert.informativeText = String(
            localized: "machines.rename.message",
            defaultValue: "The label is display-only. The machine keeps its name as its address."
        )
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = currentLabel ?? ""
        field.placeholderString = String(localized: "machines.rename.placeholder", defaultValue: "Label")
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.addButton(withTitle: String(localized: "machines.rename.confirm", defaultValue: "Rename"))
        alert.addButton(withTitle: String(localized: "common.cancel", defaultValue: "Cancel"))
        let respond: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .alertFirstButtonReturn else { return }
            let label = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            var arguments = ["vm", "rename", id]
            if label.isEmpty {
                arguments.append("--clear")
            } else {
                arguments.append(label)
            }
            onWillMutate(operationLabel(verb: ["rename"], id: id))
            if !launch(arguments: arguments, onDidMutate: onDidMutate) {
                onDidMutate()
            }
        }
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            alert.beginSheetModal(for: window, completionHandler: respond)
        } else {
            respond(alert.runModal())
        }
    }

    @MainActor
    private static func presentDeleteConfirmation(
        id: String,
        onWillMutate: @escaping @MainActor (String) -> Void = { _ in },
        onDidMutate: @escaping @MainActor () -> Void
    ) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        let format = String(
            localized: "machines.delete.title",
            defaultValue: "Delete machine “%@”?"
        )
        alert.messageText = String(format: format, id)
        alert.informativeText = String(
            localized: "machines.delete.message",
            defaultValue: "This permanently deletes the machine and everything stored on it. This cannot be undone."
        )
        alert.addButton(withTitle: String(localized: "machines.delete.confirm", defaultValue: "Delete"))
        alert.addButton(withTitle: String(localized: "common.cancel", defaultValue: "Cancel"))
        alert.buttons.first?.hasDestructiveAction = true
        let respond: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .alertFirstButtonReturn else { return }
            onWillMutate(operationLabel(verb: ["rm"], id: id))
            if !launch(
                arguments: ["vm", "rm", id],
                onSuccess: {
                    // The machine is gone; its workspaces would only sit there "Connected".
                    AppDelegate.shared?.closeWorkspaces(forManagedCloudVMID: id)
                },
                onDidMutate: onDidMutate
            ) {
                onDidMutate()
            }
        }
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            alert.beginSheetModal(for: window, completionHandler: respond)
        } else {
            respond(alert.runModal())
        }
    }
}
