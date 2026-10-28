import Foundation
public import Observation
public import CmuxNextDesign
public import CmuxNextIcons

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

    /// The row's icon: the catalog icon whose meaning is this kind.
    public var icon: IconName {
        switch self {
        case .local: .machineLocal
        case .cloud: .cloud
        case .ssh: .machineRemote
        case .server: .machineMac
        }
    }
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
    /// The link is being made (a spinner, not "Offline").
    public let isConnecting: Bool
    /// The last check's outcome; nil before one ran in this app run.
    public let health: HostHealth?
    /// The step the last check flagged (its first failure, else its first warning).
    public let healthStep: HostStep?

    /// - Parameter kind: nil takes `.local` for this Mac and `.ssh` for any other machine.
    public init(id: String, name: String, isConnected: Bool, isLocal: Bool, kind: MachineKind? = nil, isConnecting: Bool = false,
                health: HostHealth? = nil, healthStep: HostStep? = nil) {
        self.id = id
        self.name = name
        self.isConnected = isConnected
        self.isLocal = isLocal
        self.kind = kind ?? (isLocal ? .local : .ssh)
        self.isConnecting = !isConnected && isConnecting
        self.health = health
        self.healthStep = healthStep
    }

    /// The tooltip of the status dot: which step the last check flagged.
    public var healthHelp: String? {
        switch health {
        case .ok: AddMachineStrings.healthOK
        case .warning: AddMachineStrings.healthWarning(healthStep.map(AddMachineStrings.step) ?? "")
        case .failing: AddMachineStrings.healthFailing(healthStep.map(AddMachineStrings.step) ?? "")
        case nil: nil
        }
    }

    /// The link state in words: Connected, Connecting… or Offline.
    public var stateText: String {
        isConnected ? AddMachineStrings.connected : isConnecting ? AddMachineStrings.connecting : AddMachineStrings.offline
    }

    /// What VoiceOver reads for the row: its name, its link state and its last check.
    var accessibilityText: String {
        [name, stateText, healthHelp ?? ""].filter { !$0.isEmpty }.joined(separator: ", ")
    }
}

/// How the Machines section lays out its machines (`machines.section.style`, Debug Settings > Server).
/// Every style keeps every machine and every action; they differ in grouping and in how much each row says.
public nonisolated enum MachineSectionStyle: String, Sendable, CaseIterable, Hashable, TunableChoice {
    /// This Mac, then a header per kind (Cloud, SSH, Servers) over one-line rows. The link state shows
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

    /// Whether machines sit under a header per kind.
    public var groupsByKind: Bool { self != .flat }
    /// Whether each row has a second line with its link state.
    public var showsStateLine: Bool { self != .compact }

    /// `rows` in this style's groups: one untitled group for `.flat`; otherwise this Mac first with no
    /// header, then Cloud, SSH and server machines under their headers, each in the order given.
    /// A kind with no machine has no group.
    public func groups(_ rows: [MachineSectionRow]) -> [MachineSectionGroup] {
        guard groupsByKind else { return rows.isEmpty ? [] : [MachineSectionGroup(id: "all", kind: nil, rows: rows)] }
        return MachineKind.allCases.compactMap { kind in
            let members = rows.filter { $0.kind == kind }
            guard !members.isEmpty else { return nil }
            return MachineSectionGroup(id: kind.rawValue, kind: kind == .local ? nil : kind, rows: members)
        }
    }
}

/// One group of the Machines section: its header's kind (nil: no header) and its machines.
public nonisolated struct MachineSectionGroup: Identifiable, Hashable, Sendable {
    public let id: String
    /// The kind its header names; nil draws no header (this Mac, or the flat list).
    public let kind: MachineKind?
    public let rows: [MachineSectionRow]

    /// The header's text, nil for no header.
    public var title: String? { kind.flatMap(AddMachineStrings.group) }
}

/// The Machines section's rows: this Mac, then every Cloud, SSH and server machine the app knows,
/// with whether each is connected and how its last check went (the App reads them from its machine
/// registry; ``MachineSectionView`` shows them).
public nonisolated enum MachineSectionModel {
    /// Sample machines, one of each kind and state, for the gallery and captures on a slot with no
    /// remote machine (`machines.section.fixture`). Names are made up.
    public static let fixtureRows: [MachineSectionRow] = [
        MachineSectionRow(id: "fixture-cloud-1", name: "atlas-web", isConnected: true, isLocal: false, kind: .cloud, health: .ok),
        MachineSectionRow(id: "fixture-cloud-2", name: "gpu-box", isConnected: false, isLocal: false, kind: .cloud, isConnecting: true),
        MachineSectionRow(id: "fixture-ssh-1", name: "linux-box", isConnected: true, isLocal: false, kind: .ssh, health: .warning, healthStep: .update),
        MachineSectionRow(id: "fixture-ssh-2", name: "build-host", isConnected: false, isLocal: false, kind: .ssh),
        MachineSectionRow(id: "fixture-server-1", name: "studio", isConnected: true, isLocal: false, kind: .server),
    ]
}

/// The Machines section's sizes: one icon column and one inset, so every icon, name and header starts
/// on the same lines.
enum MachineSectionMetrics {
    /// The section's leading and trailing inset (rows and headers alike).
    static var inset: CGFloat { Metrics.panelInset }
    /// Every row's icon slot, so names start on one line whatever the icon's own width.
    static var iconColumn: CGFloat { Metrics.iconSize }
    /// Between the icon column and the name.
    static var iconGap: CGFloat { Metrics.panelInset }
    /// A one-line row's height.
    static var rowHeight: CGFloat { DesignTokens.controlRow }
    /// A trailing icon button's side.
    static var buttonSide: CGFloat { DesignTokens.controlIcon }
}
