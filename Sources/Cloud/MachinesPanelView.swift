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

/// Right-sidebar Machines tab: the user's cloud machine fleet. Matches the
/// Vault/Feed visual language — compact 13pt rows, full-width hover
/// backgrounds, chrome-pill control bar. Rows receive immutable
/// `MachineSnapshot`s plus a closure bundle only (snapshot-boundary rule);
/// every mutation routes through the shared Cloud VM action path.
struct MachinesPanelView: View {
    @StateObject private var viewModel = MachinesPanelViewModel()
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
                .padding(.leading, 8)
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
                .padding(.leading, 8)
                .help(viewModel.lastErrorDescription ?? "")
            } else if let plan = viewModel.plan {
                MachinePlanMeter(plan: plan)
            }
            Spacer(minLength: 4)
            MachinesChromeIconButton(
                symbolName: "arrow.clockwise",
                accessibilityLabel: String(localized: "machines.refresh", defaultValue: "Refresh Machines"),
                isBusy: viewModel.isLoading
            ) {
                viewModel.refresh()
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
        if viewModel.machines.isEmpty {
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

    /// ＋ on a free plan at its ceiling is the upgrade moment: open the Pro flow
    /// instead of launching a create that the backend would only paywall.
    private func requestNewMachine() {
        if let plan = viewModel.plan, plan.isAtLimit, !plan.isPaidPlan {
            ProUpgradePresenter.present()
            return
        }
        viewModel.beginOperation(String(localized: "machines.operation.create", defaultValue: "Creating a new machine\u{2026}"))
        let didStart = MachineRowActions.openNewMachine { [weak viewModel] _ in
            viewModel?.endOperation()
        }
        if !didStart {
            // A sign-out can race the button click. CloudVMActionLauncher
            // opens the shared sign-in flow and returns false; clear the
            // panel's progress state because no completion callback follows.
            viewModel.endOperation()
        }
    }

    private var machinesList: some View {
        let actions = MachineRowActions.bound(
            onWillMutate: { [weak viewModel] label in viewModel?.beginOperation(label) },
            onDidMutate: { [weak viewModel] in viewModel?.endOperation() }
        )
        return ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(viewModel.machines) { machine in
                    MachineRow(machine: machine, actions: actions)
                }
            }
            .padding(.vertical, 6)
        }
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
                Image(systemName: "server.rack")
                    .font(.system(size: 26, weight: .light))
                    .foregroundColor(.secondary.opacity(0.55))
                Text(String(localized: "machines.empty.title", defaultValue: "No machines yet"))
                    .cmuxFont(size: 13)
                    .foregroundColor(.primary.opacity(0.85))
                Text(String(
                    localized: "machines.empty.subtitle",
                    defaultValue: "A machine is a persistent cloud computer. It keeps your files forever and costs nothing while it sleeps."
                ))
                .cmuxFont(size: 12)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
                Button {
                    requestNewMachine()
                } label: {
                    Text(String(localized: "machines.empty.create", defaultValue: "New Machine"))
                        .cmuxFont(size: 12)
                }
                .padding(.top, 2)
            } else {
                ProgressView()
                    .controlSize(.small)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The activity-monitor line under a machine: three gauges (CPU, memory, disk)
/// with used / total, or "Asleep · free" when the machine is hibernated.
/// A narrow sidebar drops Disk, then Mem, instead of ever wrapping the
/// gauges' text mid-character across lines.
private struct MachineStatsLine: View {
    let stats: VMStats

    var body: some View {
        switch stats.state {
        case .awake:
            ViewThatFits(in: .horizontal) {
                awakeGauges(showMemory: true, showDisk: true)
                awakeGauges(showMemory: true, showDisk: false)
                awakeGauges(showMemory: false, showDisk: false)
            }
            .accessibilityElement(children: .combine)
        case .asleep:
            HStack(spacing: 10) {
                Text(String(localized: "machines.stats.asleep", defaultValue: "Asleep \u{00B7} free while it sleeps"))
                    .cmuxFont(size: 10.5)
                    .foregroundColor(.secondary.opacity(0.7))
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let total = stats.memoryTotalMb {
                    Text(String(format: String(localized: "machines.stats.provisioned", defaultValue: "%@ GB"), Self.gb(total)))
                        .cmuxFont(size: 10.5)
                        .foregroundColor(.secondary.opacity(0.55))
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            .accessibilityElement(children: .combine)
        case .unknown:
            EmptyView()
        }
    }

    private func awakeGauges(showMemory: Bool, showDisk: Bool) -> some View {
        HStack(spacing: 10) {
            if let cpu = stats.cpuPercent {
                gauge(
                    label: String(localized: "machines.stats.cpu", defaultValue: "CPU"),
                    fraction: cpu / 100,
                    text: "\(Int(cpu.rounded()))%"
                )
            }
            if showMemory, let used = stats.memoryUsedMb, let total = stats.memoryTotalMb, total > 0 {
                gauge(
                    label: String(localized: "machines.stats.memory", defaultValue: "Mem"),
                    fraction: Double(used) / Double(total),
                    text: Self.gbPair(usedMb: used, totalMb: total)
                )
            }
            if showDisk, let used = stats.diskUsedMb, let total = stats.diskTotalMb, total > 0 {
                gauge(
                    label: String(localized: "machines.stats.disk", defaultValue: "Disk"),
                    fraction: Double(used) / Double(total),
                    text: Self.gbPair(usedMb: used, totalMb: total)
                )
            }
        }
    }

    private func gauge(label: String, fraction: Double, text: String) -> some View {
        let clamped = max(0, min(1, fraction))
        return HStack(spacing: 4) {
            Text(label)
                .cmuxFont(size: 10)
                .foregroundColor(.secondary.opacity(0.6))
                .lineLimit(1)
                .fixedSize()
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule().fill(gaugeColor(clamped)).frame(width: 34 * clamped)
            }
            .frame(width: 34, height: 4)
            Text(text)
                .cmuxFont(size: 10)
                .foregroundColor(.secondary.opacity(0.8))
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize()
        }
        .accessibilityLabel("\(label) \(text)")
    }

    private func gaugeColor(_ fraction: Double) -> Color {
        if fraction >= 0.9 { return Color.red.opacity(0.8) }
        if fraction >= 0.7 { return Color.orange.opacity(0.85) }
        return Color.accentColor.opacity(0.75)
    }

    static func gb(_ mb: Int) -> String {
        let value = Double(mb) / 1024
        return value >= 10 ? String(format: "%.0f", value) : String(format: "%.1f", value)
    }

    static func gbPair(usedMb: Int, totalMb: Int) -> String {
        "\(gb(usedMb))/\(gb(totalMb)) GB"
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
        .padding(.leading, 8)
        .help(meterHelp)
        .accessibilityElement(children: .combine)
    }

    private var meterText: String {
        let format = String(
            localized: "machines.meter.count",
            defaultValue: "%1$d of %2$d machines"
        )
        return String(format: format, plan.activeCount, plan.maxActiveVms)
    }

    private var meterHelp: String {
        if plan.isAtLimit && !plan.isPaidPlan {
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

private struct MachinesChromeIconButton: View {
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
    static func openNewMachine(onCompletion: ((CloudVMActionLauncher.Completion) -> Void)? = nil) -> Bool {
        // `vm new` mints a fresh machine with its own persistent home and
        // attaches it; the base slot stays reachable via the ＋ menu's Open Base.
        let socketPath = TerminalController.shared.activeSocketPath(
            preferredPath: SocketControlSettings.socketPath()
        )
        return CloudVMActionLauncher.shared.start(
            socketPath: socketPath,
            preferredWindow: NSApp.keyWindow ?? NSApp.mainWindow,
            arguments: ["vm", "new"],
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

private struct MachineRow: View, Equatable {
    let machine: MachineSnapshot
    let actions: MachineRowActions
    @State private var isHovered = false

    static func == (lhs: MachineRow, rhs: MachineRow) -> Bool {
        // Skip body re-eval during scroll when the snapshot is unchanged.
        // The closure bundle isn't compared (it comes from stable parent state).
        lhs.machine == rhs.machine
    }

    var body: some View {
        HStack(spacing: 8) {
            activityDot
            VStack(alignment: .leading, spacing: 1) {
                Text(machine.displayName)
                    .cmuxFont(size: 13)
                    .foregroundColor(.primary.opacity(0.92))
                    .lineLimit(1)
                    .truncationMode(.tail)
                HStack(spacing: 4) {
                    // A box's type at a glance: a desktop machine has its screen,
                    // a base machine is shell-only.
                    Image(systemName: machine.isDesktop ? "display" : "terminal")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(.secondary.opacity(0.6))
                    Text(subtitle)
                        .cmuxFont(size: 11)
                        .foregroundColor(.secondary.opacity(0.75))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                if let stats = machine.stats {
                    MachineStatsLine(stats: stats)
                        .padding(.top, 2)
                }
            }
            Spacer(minLength: 8)
            // Hover verbs: the screen (desktop machines only) and delete. The shell is
            // the row itself — double-click, or Open Shell in the menu. The buttons are
            // always laid out and only fade in, so hovering never reflows the row.
            HStack(spacing: 2) {
                if machine.isDesktop {
                    MachinesChromeIconButton(
                        symbolName: "display",
                        accessibilityLabel: String(localized: "machines.row.openDesktop", defaultValue: "Open Desktop"),
                        isBusy: false
                    ) {
                        actions.openDesktop(machine.id)
                    }
                }
                MachinesChromeIconButton(
                    symbolName: "trash",
                    accessibilityLabel: String(localized: "machines.row.delete", defaultValue: "Delete Machine"),
                    isBusy: false
                ) {
                    actions.confirmDelete(machine.id)
                }
            }
            .opacity(isHovered ? 1 : 0)
            .allowsHitTesting(isHovered)
            .accessibilityHidden(!isHovered)
        }
        .padding(.leading, 12)
        .padding(.trailing, 10)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .background(rowBackground)
        .onHover { isHovered = $0 }
        .onTapGesture(count: 2) {
            if machine.freeAccess == .expired {
                actions.promptUpgrade()
            } else {
                actions.openShell(machine.id)
            }
        }
        .help(helpText)
        .contextMenu { menuItems }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(machine.displayName), \(machine.activityLabel)")
    }

    @ViewBuilder
    private var activityDot: some View {
        if machine.freeAccess == .expired {
            Image(systemName: "lock.fill")
                .font(.system(size: 8, weight: .semibold))
                .foregroundColor(.secondary.opacity(0.8))
                .frame(width: 7)
        } else {
            Circle()
                .fill(dotColor)
                .frame(width: 7, height: 7)
        }
    }

    private var rowBackground: some View {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(isHovered ? Color.primary.opacity(0.05) : Color.clear)
            .padding(.horizontal, 6)
    }

    private var dotColor: Color {
        switch machine.activity {
        case .ready: return Color.green.opacity(0.85)
        case .pending: return Color.orange.opacity(0.9)
        case .attention: return Color.red.opacity(0.85)
        }
    }

    private var subtitle: String {
        var parts: [String] = []
        if machine.label?.isEmpty == false {
            // Labeled machines keep their address visible: the id is what CLI
            // verbs and URLs use.
            parts.append(machine.id)
        }
        parts.append(machine.kindLabel)
        if let createdAt = machine.createdAt {
            parts.append(Self.relativeFormatter.localizedString(for: createdAt, relativeTo: Date()))
        }
        switch machine.freeAccess {
        case .unrestricted:
            break
        case .expired:
            parts.append(String(localized: "machines.row.locked", defaultValue: "Locked"))
        case .active(let daysLeft):
            parts.append(
                daysLeft == 1
                    ? String(localized: "machines.row.dayLeft", defaultValue: "1 day left")
                    : String(format: String(localized: "machines.row.daysLeft", defaultValue: "%d days left"), daysLeft)
            )
        }
        return parts.joined(separator: " · ")
    }

    private var helpText: String {
        [machine.displayName, machine.activityLabel, machine.image].joined(separator: "\n")
    }

    @ViewBuilder
    private var menuItems: some View {
        if machine.freeAccess == .expired {
            Button(String(localized: "machines.menu.upgradeToReconnect", defaultValue: "Upgrade to Reconnect\u{2026}")) {
                actions.promptUpgrade()
            }
        } else {
            Button(String(localized: "machines.menu.openShell", defaultValue: "Open Shell")) {
                actions.openShell(machine.id)
            }
            if machine.isDesktop {
                Button(String(localized: "machines.menu.openDesktop", defaultValue: "Open Desktop")) {
                    actions.openDesktop(machine.id)
                }
            }
        }
        Divider()
        Button(String(localized: "machines.menu.rename", defaultValue: "Rename\u{2026}")) {
            actions.promptRename(machine.id, machine.label)
        }
        Button(String(localized: "machines.menu.status", defaultValue: "Status")) {
            actions.runCommand(machine.id, ["vm", "status"])
        }
        Button(String(localized: "machines.menu.checkpoint", defaultValue: "Checkpoint")) {
            actions.runCommand(machine.id, ["vm", "snapshot"])
        }
        Button(String(localized: "machines.menu.fork", defaultValue: "Fork")) {
            actions.runCommand(machine.id, ["vm", "fork"])
        }
        Divider()
        Button(role: .destructive) {
            actions.confirmDelete(machine.id)
        } label: {
            Text(String(localized: "machines.menu.delete", defaultValue: "Delete…"))
        }
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()
}
