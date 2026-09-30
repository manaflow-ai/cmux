import CmuxCloud
import CmuxSettingsUI
import Foundation

/// Everything a Cloud menu needs to decide what to show, as one value.
struct CloudMenuContext {
    enum Account {
        /// Cloud is off (feature flag, managed policy): no Cloud rows at all.
        case unavailable
        case signedOut(isSigningIn: Bool)
        case signedIn(CloudMenuAccount)
    }

    var account: Account
    var machines: [MachineSnapshot] = []
    var loadState: CloudMenuModel.LoadState = .idle
}

struct CloudMenuAccount {
    var email: String?
    var displayName: String?
    var teams: [AccountTeamSummary] = []
    var selectedTeamID: String?
    var isSelectingTeam = false

    var activeTeamName: String? {
        teams.first(where: { $0.id == selectedTeamID })?.displayName
    }
}

/// App-level Cloud verbs. `machine` carries the per-machine verbs shared with
/// the sidebar context menu.
struct CloudMenuActions {
    var signIn: @MainActor () -> Void
    var signOut: @MainActor () -> Void
    var selectTeam: @MainActor (String) -> Void
    var newWorkspace: @MainActor () -> Void
    var newMachine: @MainActor () -> Void
    var showMachines: @MainActor () -> Void
    var openDashboard: @MainActor () -> Void
    var showDiagnostics: @MainActor () -> Void
    var upgrade: @MainActor () -> Void
    var retry: @MainActor () -> Void
    var machine: CloudMachineMenuVerbs
}

enum CloudMenuContent {
    enum Layout {
        /// The main-menu Cloud menu: everything, one level deep.
        case mainMenu
        /// A section inside the status item menu: machines inline, account
        /// and tools under "More".
        case statusItem
    }

    /// The status item shows at most this many machines inline; the rest are
    /// one click away in the sidebar.
    static let statusItemMachineLimit = 8

    static func entries(_ context: CloudMenuContext, actions: CloudMenuActions, layout: Layout) -> [CloudMenuEntry] {
        switch context.account {
        case .unavailable:
            return []
        case .signedOut(let isSigningIn):
            var entries: [CloudMenuEntry] = []
            if layout == .statusItem {
                entries.append(.header(id: "cloud.title", title: String(localized: "cloudMenu.title", defaultValue: "Cloud")))
            }
            entries.append(.action(CloudMenuAction(
                id: "cloud.signIn",
                title: isSigningIn
                    ? String(localized: "cloudMenu.signingIn", defaultValue: "Signing In…")
                    : String(localized: "cloudMenu.signIn", defaultValue: "Sign In to cmux Cloud…"),
                isEnabled: !isSigningIn,
                perform: actions.signIn
            )))
            if layout == .mainMenu {
                entries.append(.separator(id: "cloud.sep.signedOut"))
                entries.append(dashboardEntry(actions))
            }
            return entries
        case .signedIn(let account):
            switch layout {
            case .mainMenu: return mainMenuEntries(context, account: account, actions: actions)
            case .statusItem: return statusItemEntries(context, account: account, actions: actions)
            }
        }
    }

    // MARK: Layouts

    private static func mainMenuEntries(_ context: CloudMenuContext, account: CloudMenuAccount, actions: CloudMenuActions) -> [CloudMenuEntry] {
        var entries: [CloudMenuEntry] = [.header(id: "cloud.account", title: accountLine(account))]
        if let team = teamSubmenu(account, actions: actions) { entries.append(team) }
        entries.append(.separator(id: "cloud.sep.create"))
        entries += createEntries(actions)
        entries.append(.separator(id: "cloud.sep.machines"))
        entries.append(.header(id: "cloud.machines.title", title: machinesTitle(context)))
        entries += machineEntries(context, actions: actions, limit: nil)
        entries.append(.separator(id: "cloud.sep.tools"))
        entries += toolEntries(actions)
        entries.append(.separator(id: "cloud.sep.signOut"))
        entries.append(signOutEntry(actions))
        return entries
    }

    private static func statusItemEntries(_ context: CloudMenuContext, account: CloudMenuAccount, actions: CloudMenuActions) -> [CloudMenuEntry] {
        var title = machinesTitle(context)
        if let team = account.activeTeamName { title += " \u{00B7} " + team }
        var entries: [CloudMenuEntry] = [.header(id: "cloud.title", title: title)]
        entries += machineEntries(context, actions: actions, limit: statusItemMachineLimit)
        entries += createEntries(actions)
        var more: [CloudMenuEntry] = [.header(id: "cloud.more.account", title: accountLine(account))]
        if let team = teamSubmenu(account, actions: actions) { more.append(team) }
        more.append(.separator(id: "cloud.more.sep.tools"))
        more += toolEntries(actions)
        more.append(.separator(id: "cloud.more.sep.signOut"))
        more.append(signOutEntry(actions))
        entries.append(.submenu(CloudMenuSubmenu(
            id: "cloud.more",
            title: String(localized: "cloudMenu.more", defaultValue: "More Cloud"),
            children: more
        )))
        return entries
    }

    // MARK: Sections

    static func machinesTitle(_ context: CloudMenuContext) -> String {
        if context.loadState == .loading, context.machines.isEmpty {
            return String(localized: "cloudMenu.machines.loading", defaultValue: "Cloud Machines · Loading…")
        }
        return String(localized: "cloudMenu.machines.title", defaultValue: "Cloud Machines")
    }

    private static func machineEntries(_ context: CloudMenuContext, actions: CloudMenuActions, limit: Int?) -> [CloudMenuEntry] {
        if case .failed(let problem) = context.loadState, context.machines.isEmpty {
            return problemEntries(problem, actions: actions)
        }
        if context.machines.isEmpty {
            guard context.loadState == .loaded else { return [] }
            return [.header(id: "cloud.machines.empty", title: String(localized: "cloudMenu.machines.empty", defaultValue: "No machines yet"))]
        }
        let shown = limit.map { Array(context.machines.prefix($0)) } ?? context.machines
        var entries: [CloudMenuEntry] = shown.map { machine in
            .submenu(CloudMenuSubmenu(
                id: "machine.\(machine.id)",
                title: machine.displayName,
                detail: machine.activityLabel,
                tone: CloudMenuTone(machine),
                children: actions.machine.submenuEntries(machine)
            ))
        }
        let hidden = context.machines.count - shown.count
        if hidden > 0 {
            entries.append(.action(CloudMenuAction(
                id: "cloud.machines.showAll",
                title: String(localized: "cloudMenu.machines.showAll", defaultValue: "Show All Machines…"),
                perform: actions.showMachines
            )))
        }
        return entries
    }

    /// Say the true thing: an expired session needs sign-in, a plan gate needs
    /// an upgrade, and only transient failures offer Retry.
    private static func problemEntries(_ problem: MachinesPanelViewModel.CloudListProblem, actions: CloudMenuActions) -> [CloudMenuEntry] {
        switch problem {
        case .sessionRejected:
            return [
                .header(id: "cloud.problem", title: String(localized: "cloudMenu.problem.session", defaultValue: "Your Cloud session expired")),
                .action(CloudMenuAction(id: "cloud.problem.signIn", title: String(localized: "cloudMenu.signInAgain", defaultValue: "Sign In Again…"), perform: actions.signIn)),
            ]
        case .requiresPro:
            return [
                .header(id: "cloud.problem", title: String(localized: "cloudMenu.problem.requiresPro", defaultValue: "Cloud machines need cmux Pro")),
                .action(CloudMenuAction(id: "cloud.problem.upgrade", title: String(localized: "cloudMenu.upgrade", defaultValue: "Upgrade to Pro…"), perform: actions.upgrade)),
            ]
        case .unreachable:
            return [
                .header(id: "cloud.problem", title: String(localized: "cloudMenu.problem.unreachable", defaultValue: "Could not reach cmux Cloud")),
                .action(CloudMenuAction(id: "cloud.problem.retry", title: String(localized: "cloudMenu.retry", defaultValue: "Try Again"), perform: actions.retry)),
            ]
        }
    }

    private static func createEntries(_ actions: CloudMenuActions) -> [CloudMenuEntry] {
        [
            .action(CloudMenuAction(
                id: "cloud.newWorkspace",
                title: String(localized: "menu.file.newCloudWorkspace", defaultValue: "New Cloud Workspace"),
                shortcut: .newCloudWorkspace,
                perform: actions.newWorkspace
            )),
            .action(CloudMenuAction(
                id: "cloud.newMachine",
                title: String(localized: "cloudMenu.newMachine", defaultValue: "New Cloud Machine…"),
                shortcut: .newCloudMachine,
                perform: actions.newMachine
            )),
        ]
    }

    private static func toolEntries(_ actions: CloudMenuActions) -> [CloudMenuEntry] {
        [
            .action(CloudMenuAction(
                id: "cloud.showMachines",
                title: String(localized: "cloudMenu.showMachines", defaultValue: "Show Machines Sidebar"),
                perform: actions.showMachines
            )),
            dashboardEntry(actions),
            .action(CloudMenuAction(
                id: "cloud.diagnostics",
                title: String(localized: "cloudMenu.diagnostics", defaultValue: "Cloud Diagnostics"),
                perform: actions.showDiagnostics
            )),
        ]
    }

    private static func dashboardEntry(_ actions: CloudMenuActions) -> CloudMenuEntry {
        .action(CloudMenuAction(
            id: "cloud.dashboard",
            title: String(localized: "cloudMenu.dashboard", defaultValue: "Open Cloud Dashboard"),
            perform: actions.openDashboard
        ))
    }

    private static func signOutEntry(_ actions: CloudMenuActions) -> CloudMenuEntry {
        .action(CloudMenuAction(
            id: "cloud.signOut",
            title: String(localized: "cloudMenu.signOut", defaultValue: "Sign Out"),
            perform: actions.signOut
        ))
    }

    /// Checkmarked teams; switching goes through the same account flow as the
    /// sidebar team picker. Hidden for accounts with no team to choose.
    private static func teamSubmenu(_ account: CloudMenuAccount, actions: CloudMenuActions) -> CloudMenuEntry? {
        guard account.teams.count > 1 else { return nil }
        let children: [CloudMenuEntry] = account.teams.map { team in
            .action(CloudMenuAction(
                id: "cloud.team.\(team.id)",
                title: team.displayName,
                isEnabled: !account.isSelectingTeam,
                isChecked: team.id == account.selectedTeamID,
                perform: { actions.selectTeam(team.id) }
            ))
        }
        return .submenu(CloudMenuSubmenu(
            id: "cloud.team",
            title: String(localized: "cloudMenu.team", defaultValue: "Team"),
            detail: account.activeTeamName,
            children: children
        ))
    }

    private static func accountLine(_ account: CloudMenuAccount) -> String {
        let who = account.email ?? account.displayName
            ?? String(localized: "cloudMenu.signedIn", defaultValue: "Signed In")
        guard let team = account.activeTeamName else { return who }
        return who + " \u{00B7} " + team
    }
}
