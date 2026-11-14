import Foundation
public import Observation
public import CmuxNextDesign

/// The last enroll or doctor report of each machine, by app machine id, for this run of the app
/// (the Machines section's status dot). Kept in memory: a relaunch shows no status until the next
/// Check Machine or add.
@Observable
public final class MachineHealthStore {
    public private(set) var reports: [String: HostReport] = [:]

    public init() {}

    public func record(_ machineID: String, _ report: HostReport) {
        reports[machineID] = report
    }
}

/// What a machine of the Machines section is: it picks the row's icon and its group.
public nonisolated enum MachineKind: String, Hashable, Sendable, CaseIterable {
    /// This Mac (the local daemon).
    case local
    /// A cmux Cloud machine.
    case cloud
    /// A machine reached over ssh.
    case ssh
    /// A paired cmux server.
    case server
    /// A machine that joined through the hub (a pair code or a one-line token) and that the app reaches
    /// through the mesh alone. A joined machine the app also connects to keeps that link's kind.
    case joined
}

/// What the machine's server says about a Cloud machine that is not simply running: a settled state
/// the row writes in words instead of a spinner (a paused machine is not connecting), or a resume
/// that is on its way (a spinner, read as "Resuming…"). Nil for a running machine and every
/// non-Cloud machine: the row follows its link.
public nonisolated enum MachineServerState: String, Hashable, Sendable, CaseIterable {
    /// Paused (the idle auto-pause or a person's Pause Machine); an attach resumes it.
    case paused
    /// A resume of the paused machine is on its way.
    case resuming
    /// The server reports the machine failed.
    case failed
    /// The machine was deleted.
    case deleted
}

/// One machine of the Machines section (a value snapshot).
public nonisolated struct MachineSectionRow: Identifiable, Hashable, Sendable {
    /// The machine id (`workspace.newOnMachine`'s `machine`).
    public let id: String
    public let name: String
    public let isConnected: Bool
    public let isLocal: Bool
    /// What the machine is: its icon and its group.
    public let kind: MachineKind
    /// The link is being made, or a resume is on its way (a spinner, not "Offline"). Never true for a
    /// machine whose server says it is paused, failed or deleted: nothing is connecting to it.
    public let isConnecting: Bool
    /// What the machine's server says when it is not simply running (``MachineServerState``); nil
    /// for a running machine and every non-Cloud machine.
    public let serverState: MachineServerState?
    /// The last check's outcome; nil before one ran in this app run.
    public let health: HostHealth?
    /// The step the last check flagged (its first failure, else its first warning).
    public let healthStep: HostStep?
    /// A machine that joined through the hub (a pair code or a one-line token): reached through the
    /// mesh, with Check, Rotate Credential and Revoke. Nil for a machine the app connects to.
    public let joined: JoinedMachine?

    /// - Parameter kind: nil takes `.local` for this Mac and `.ssh` for any other machine (a joined
    ///   machine's own row, ``joined(_:health:)``, passes `.joined`).
    /// - Parameter serverState: a settled state (paused, failed, deleted) turns the spinner off and
    ///   writes the state; `.resuming` keeps a spinner. A connected link wins over either.
    public init(id: String, name: String, isConnected: Bool, isLocal: Bool, kind: MachineKind? = nil, isConnecting: Bool = false,
                serverState: MachineServerState? = nil, health: HostHealth? = nil, healthStep: HostStep? = nil,
                joined: JoinedMachine? = nil) {
        self.id = id
        self.name = name
        self.isConnected = isConnected
        self.isLocal = isLocal
        self.kind = kind ?? (isLocal ? .local : .ssh)
        let serverState = isConnected ? nil : serverState
        self.serverState = serverState
        self.isConnecting = !isConnected && (serverState.map { $0 == .resuming } ?? isConnecting)
        self.health = health
        self.healthStep = healthStep
        self.joined = joined
    }

    /// The row of a joined machine, with its last Check from `health`.
    public static func joined(_ machine: JoinedMachine, health: HostReport?) -> MachineSectionRow {
        MachineSectionRow(id: JoinedMachine.healthID(machine.id), name: machine.name, isConnected: machine.state == .online, isLocal: false,
                          kind: .joined, health: health?.health, healthStep: health?.worstStep?.step, joined: machine)
    }

    /// The title of a row's menu item New Workspace on This Machine (`workspace.newOnMachine`).
    public static var newWorkspaceTitle: String { AddMachineStrings.newWorkspace }
}

/// How the Machines section lays out its machines (`machines.section.style`, Debug Settings > Server).
/// Every style keeps every machine and every action; they differ in grouping and in how much each row says.
public nonisolated enum MachineSectionStyle: String, Sendable, CaseIterable, Hashable, TunableChoice {
    /// This Mac, then a header per kind (Cloud, SSH, Servers, Joined) over one-line rows. The link state shows
    /// only when it is not connected: a spinner while connecting, "Offline" when down.
    case compact
    /// The same groups, with each machine's link state on a second line.
    case grouped
    /// One list with each machine's link state on a second line (the layout before the groups).
    case flat

    public var tunableTitle: String {
        switch self {
        case .compact: "Grouped, one line per machine"
        case .grouped: "Grouped, state under the name"
        case .flat: "One list, state under the name"
        }
    }
}

/// The Machines section's rows (the page webviews/src/pages/machines shows them): the App reads this
/// Mac, every Cloud, SSH and server machine and the machines that joined through the hub from its
/// registries (`MachineSectionRow.rows`, CmuxNextApp).
extension MachineSectionRow {
    /// Sample machines, one of each kind and state, for the gallery and captures on a slot with no
    /// remote machine (`machines.section.fixture`). Names are made up.
    public static let fixtures: [MachineSectionRow] = [
        MachineSectionRow(id: "fixture-cloud-1", name: "atlas-web", isConnected: true, isLocal: false, kind: .cloud, health: .ok),
        MachineSectionRow(id: "fixture-cloud-2", name: "gpu-box", isConnected: false, isLocal: false, kind: .cloud, isConnecting: true),
        MachineSectionRow(id: "fixture-cloud-3", name: "night-batch", isConnected: false, isLocal: false, kind: .cloud, serverState: .paused),
        MachineSectionRow(id: "fixture-ssh-1", name: "linux-box", isConnected: true, isLocal: false, kind: .ssh, health: .warning, healthStep: .update),
        MachineSectionRow(id: "fixture-ssh-2", name: "build-host", isConnected: false, isLocal: false, kind: .ssh),
        MachineSectionRow(id: "fixture-server-1", name: "studio", isConnected: true, isLocal: false, kind: .server),
    ]
}
