import Foundation
public import AppKit
public import Observation
public import SwiftUI
import CmuxNextDesign
import CmuxNextIcons

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

/// One machine of the Machines section (a value snapshot).
public nonisolated struct MachineSectionRow: Identifiable, Hashable, Sendable {
    /// The machine id (`workspace.newOnMachine`'s `machine`).
    public let id: String
    public let name: String
    public let isConnected: Bool
    public let isLocal: Bool
    /// The last check's outcome; nil before one ran in this app run.
    public let health: HostHealth?
    /// The step the last check flagged (its first failure, else its first warning).
    public let healthStep: HostStep?
    /// A machine that joined with a one-line token (Labs `labs.machineJoin`): reached through the
    /// mesh, with Check, Rotate Credential and Revoke. Nil for a machine the app connects to.
    public let joined: JoinedMachine?

    public init(id: String, name: String, isConnected: Bool, isLocal: Bool, health: HostHealth? = nil, healthStep: HostStep? = nil,
                joined: JoinedMachine? = nil) {
        self.id = id
        self.name = name
        self.isConnected = isConnected
        self.isLocal = isLocal
        self.health = health
        self.healthStep = healthStep
        self.joined = joined
    }

    /// Whether the row is a machine the app connects to (it can open a workspace), not a joined
    /// machine reached through the mesh alone.
    public var isLinked: Bool { joined == nil || id != joined.map { JoinedMachine.healthID($0.id) } }

    /// The row of a joined machine, with its last Check from `health`.
    public static func joined(_ machine: JoinedMachine, health: HostReport?) -> MachineSectionRow {
        MachineSectionRow(id: JoinedMachine.healthID(machine.id), name: machine.name, isConnected: machine.state == .online, isLocal: false,
                          health: health?.health, healthStep: health?.worstStep?.step, joined: machine)
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
}

/// The Machines section's rows: this Mac, then every Cloud, SSH and server machine the app knows,
/// with whether each is connected and how its last check went.
@Observable
public final class MachineSectionModel {
    public private(set) var rows: [MachineSectionRow] = []

    public init() {}

    public func update(_ next: [MachineSectionRow]) {
        if next != rows { rows = next }
    }
}

/// The Machines section: every machine with its link state and last check; New Workspace opens a
/// workspace on it (`workspace.newOnMachine`), Add Machine… opens the Add Machine card.
public struct MachineSectionListView: View {
    let model: MachineSectionModel
    let newWorkspace: @MainActor (String) -> Void
    let addMachine: @MainActor () -> Void
    /// A joined machine's "…" menu (the registry's rows for it), with the row it opens on.
    let joinedMenu: @MainActor (JoinedMachine, MachineSectionRow) -> NSMenu?
    let joinedStore: JoinedMachineStore?

    public init(model: MachineSectionModel, newWorkspace: @escaping @MainActor (String) -> Void,
                addMachine: @escaping @MainActor () -> Void, joinedStore: JoinedMachineStore? = nil,
                joinedMenu: @escaping @MainActor (JoinedMachine, MachineSectionRow) -> NSMenu? = { _, _ in nil }) {
        self.model = model
        self.newWorkspace = newWorkspace
        self.addMachine = addMachine
        self.joinedStore = joinedStore
        self.joinedMenu = joinedMenu
    }

    public var body: some View {
        let rows = model.rows
        // The store is read here, above the ForEach; each row gets values and closures only.
        let openMenu = joinedStore?.openMenu, busy = joinedStore?.busy ?? [], failed = joinedStore?.failed ?? [:]
        VStack(alignment: .leading, spacing: 2) {
            ForEach(rows) { row in
                if let joined = row.joined {
                    JoinedMachineRowHost(
                        snapshot: .init(row: row, machine: joined, busy: busy.contains(joined.id), failed: failed[joined.id],
                                        menuOpen: openMenu == joined.id),
                        actions: .init(newWorkspace: { newWorkspace(row.id) }, menu: { joinedMenu(joined, row) }))
                } else {
                HStack(alignment: .center, spacing: Metrics.panelInset) {
                    Icon(row.isLocal ? .machineLocal : .machineRemote, size: Metrics.iconSize)
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: Metrics.space2) {
                            Text(verbatim: row.name).font(Font(Typography.body)).lineLimit(1)
                            MachineHealthDot(health: row.health)
                        }
                        Text(verbatim: row.isConnected ? AddMachineStrings.connected : AddMachineStrings.offline)
                            .font(Font(Typography.caption)).foregroundStyle(.secondary)
                    }
                    .themedHelp(row.healthHelp ?? "")
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(Text(verbatim: [row.name, row.isConnected ? AddMachineStrings.connected : AddMachineStrings.offline,
                                                        row.healthHelp ?? ""].filter { !$0.isEmpty }.joined(separator: ", ")))
                    Spacer(minLength: Metrics.panelInset)
                    Button {
                        newWorkspace(row.id)
                    } label: {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(Text(AddMachineStrings.newWorkspace))
                    .disabled(!row.isConnected)
                }
                .padding(.vertical, 2).padding(.horizontal, Metrics.panelInset)
                }
            }
            Button(action: addMachine) {
                Label(AddMachineStrings.addMachine, systemImage: "plus.circle")
                    .font(Font(Typography.body))
            }
            .buttonStyle(.borderless)
            .padding(.vertical, 2).padding(.horizontal, Metrics.panelInset)
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The last check of a machine as a small mark after its name: a check when every step passed, a
/// dot in the warning or danger color otherwise, nothing before a check ran.
/// A joined machine's AppKit row (`JoinedMachineRowView`) in this list, until the section's rows are
/// all AppKit (plans/cmux-next/no-swiftui-DESIGN.md: Machines section, AppKit rows).
struct JoinedMachineRowHost: NSViewRepresentable {
    let snapshot: JoinedMachineRowView.Snapshot
    let actions: JoinedMachineRowView.Actions

    func makeNSView(context: Context) -> JoinedMachineRowView { JoinedMachineRowView() }

    func updateNSView(_ view: JoinedMachineRowView, context: Context) { view.update(snapshot, actions) }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: JoinedMachineRowView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? nsView.frame.width, height: JoinedMachineMetrics.rowHeight)
    }
}

struct MachineHealthDot: View {
    let health: HostHealth?

    var body: some View {
        switch health {
        case .ok:
            Icon(.statusComplete, size: AddMachineMetrics.dotSize * 2).foregroundStyle(Color(nsColor: Palette.success))
        case .warning:
            Circle().fill(Color(nsColor: Palette.attention)).frame(width: AddMachineMetrics.dotSize, height: AddMachineMetrics.dotSize)
        case .failing:
            Circle().fill(Color(nsColor: Palette.danger)).frame(width: AddMachineMetrics.dotSize, height: AddMachineMetrics.dotSize)
        case nil:
            EmptyView()
        }
    }
}
