public import AppKit
import CmuxNextCompat
import Observation
public import CmuxNextPages
public import CmuxNextSettings

public extension PageDescriptor {
    /// The right sidebar's Machines section (webviews/src/pages/machines): cmux-page://cmux.machines/.
    /// Its ops are its own (``MachineSectionPageProvider``); it runs no other app action.
    static let machines = PageDescriptor(id: "cmux.machines", resource: "machines", namespaces: [MachineSectionPageProvider.prefix])
}

/// Serves the Machines section page's `cmux.machines.*` ops from the machine registry, each
/// machine's last check, the person's hub-joined machines and the section's layout tunable:
/// - `snapshot` → `{rows, style, busy, failed, openMenu?, cloudTeam?}` (webviews/src/pages/machines/types.ts);
/// - stream `changes` → the whole snapshot each time it changes, only while the section shows: a
///   hidden section observes nothing but whether it shows, and the newest snapshot arrives when it
///   shows again;
/// - `newWorkspace {machine}` → `workspace.newOnMachine`; `addMachine` → `device.add` (Add Device);
/// - `menu {row, menu, x, y}` → the registry's native menu for the row at the page point, answered
///   once it closes (`row`: New Workspace on This Machine; `joined`: Check, Rotate Credential, Revoke…);
/// - `remove {row}` → a joined machine's Remove, after the page's own question: revoked if it still
///   can join, and off every machine list (`cmux device remove`, whose record is cmux-tui's).
/// Every op but `snapshot` runs only on the person's own input, on a row the section shows.
/// The layout (groups, order, words) is the page's.
@MainActor @Observable
public final class MachineSectionPageProvider: PageProvider {
    public nonisolated static let prefix = "cmux.machines."
    static let snapshotOp = "cmux.machines.snapshot"
    static let changesStream = "cmux.machines.changes"
    static let newWorkspaceOp = "cmux.machines.newWorkspace"
    static let addMachineOp = "cmux.machines.addMachine"
    static let menuOp = "cmux.machines.menu"
    static let removeOp = "cmux.machines.remove"
    /// The menus `menuOp` opens: a row's New Workspace, and a joined machine's Check / Rotate / Revoke.
    static let rowMenu = "row", joinedMenu = "joined"

    /// What the page reads and runs, so a test can stand in for the app.
    public struct Dependencies {
        /// The section's rows now (`MachineSectionRow.rows`, CmuxNextApp).
        var rows: @MainActor () -> [MachineSectionRow]
        var style: @MainActor () -> MachineSectionStyle
        var joined: @MainActor () -> JoinedMachineStore?
        /// New Workspace on a machine (`workspace.newOnMachine`); false when it did not run.
        var newWorkspace: @MainActor (_ machine: String) -> Bool
        /// Add Machine… (`device.add`).
        var addMachine: @MainActor () -> Bool
        /// Shows `menu` at a point of the page (CSS pixels) and returns once it closes.
        var present: @MainActor (NSMenu, CGPoint) async -> Void
        /// The registry's rows of a row's menu (`row`) or a joined machine's (`joined`); nil: none.
        var menu: @MainActor (_ kind: String, _ row: MachineSectionRow) -> NSMenu?
        /// The team the Cloud machines belong to (the active team): its name and whether it is the
        /// person's own, named on the Cloud header; nil signed out or before membership loads.
        var cloudTeam: @MainActor () -> (name: String, personal: Bool)?

        public init(rows: @escaping @MainActor () -> [MachineSectionRow], style: @escaping @MainActor () -> MachineSectionStyle,
                    joined: @escaping @MainActor () -> JoinedMachineStore?, newWorkspace: @escaping @MainActor (String) -> Bool,
                    addMachine: @escaping @MainActor () -> Bool, present: @escaping @MainActor (NSMenu, CGPoint) async -> Void,
                    menu: @escaping @MainActor (String, MachineSectionRow) -> NSMenu?,
                    cloudTeam: @escaping @MainActor () -> (name: String, personal: Bool)? = { nil }) {
            self.cloudTeam = cloudTeam
            self.rows = rows
            self.style = style
            self.joined = joined
            self.newWorkspace = newWorkspace
            self.addMachine = addMachine
            self.present = present
            self.menu = menu
        }
    }

    /// Fills in the presenter once the page exists (the page is made with this provider).
    @ObservationIgnored var present: @MainActor (NSMenu, CGPoint) async -> Void
    @ObservationIgnored private let dependencies: Dependencies
    /// Whether the section shows. A stream observes only this while it is hidden (no snapshot is made
    /// and no row is read), and the rows again once it shows.
    public private(set) var isShown = false
    /// Each live stream's sender, which the show runs at once; a cancelled one goes at the next show.
    @ObservationIgnored private var streams: [(task: Task<Void, Never>, send: @MainActor () -> Void)] = []

    public init(dependencies: Dependencies) {
        self.dependencies = dependencies
        present = dependencies.present
    }

    /// The section showed or hid. Showing sends each stream the newest snapshot if it changed meanwhile.
    public func setShown(_ shown: Bool) {
        guard shown != isShown else { return }
        isShown = shown
        streams.removeAll { $0.task.isCancelled }
        if shown { for stream in streams { stream.send() } }
    }

    public func call(_ op: String, params: JSONValue, context: PageCallContext) async throws -> JSONValue {
        switch op {
        case Self.snapshotOp:
            return snapshot()
        case Self.newWorkspaceOp:
            try Self.requireGesture(context)
            // Only a machine the section shows and that is connected: the page names a row, never any daemon.
            guard let machine = params["machine"]?.stringValue,
                  dependencies.rows().contains(where: { $0.id == machine && $0.isConnected }) else {
                throw PageError.invalidParams("machine is not a connected machine of the section")
            }
            return ["ran": .bool(dependencies.newWorkspace(machine))]
        case Self.addMachineOp:
            try Self.requireGesture(context)
            return ["ran": .bool(dependencies.addMachine())]
        case Self.menuOp:
            try Self.requireGesture(context)
            // A row the section shows (never a fleet daemon the rows leave out), and a menu that row has: its
            // New Workspace row, or a joined machine's menu only on a joined row. Every item the menu runs
            // targets that row's machine, and a menu choice is the person's own input.
            guard let id = params["row"]?.stringValue, let kind = params["menu"]?.stringValue,
                  let row = dependencies.rows().first(where: { $0.id == id }) else {
                throw PageError.invalidParams("row is not a machine of the section")
            }
            // A joined machine with no workspace link of its own (its row is only `joined:<id>`) has no
            // New Workspace: its row menu is refused like any menu the row does not have.
            let linked = row.joined.map { row.id != JoinedMachine.healthID($0.id) } ?? true
            guard (kind == Self.rowMenu && linked) || (kind == Self.joinedMenu && row.joined != nil) else {
                throw PageError.invalidParams("row has no \(kind) menu")
            }
            guard let menu = dependencies.menu(kind, row) else { return .object([:]) }
            let point = CGPoint(x: params["x"]?.doubleValue ?? 0, y: params["y"]?.doubleValue ?? 0)
            await present(menu, point)
            return .object([:])
        case Self.removeOp:
            try Self.requireGesture(context)
            // Only a joined machine the section shows, while it shows; the page names its row, never a machine id.
            guard isShown else { throw PageError.invalidParams("the Machines section is hidden") }
            guard let id = params["row"]?.stringValue, let machine = dependencies.rows().first(where: { $0.id == id })?.joined,
                  let joined = dependencies.joined() else {
                throw PageError.invalidParams("row is not a joined machine of the section")
            }
            return ["removed": .bool(await joined.perform(.remove, machine.id))]
        default:
            throw PageError.unknownOp(op)
        }
    }

    /// New Workspace, Add Machine and the row menus run only on the person's own click or key in the page
    /// (`context.userGesture`, which the page router records from real input; page script cannot set it).
    private static func requireGesture(_ context: PageCallContext) throws {
        guard context.userGesture else {
            throw PageError(code: PageNativeOp.userOnlyCode, message: "Only a person can do this in the Machines section")
        }
    }

    public func subscribe(_ stream: String, filter: JSONValue, context: PageCallContext,
                   onEvent: @escaping @MainActor (JSONValue) -> Void) async throws -> PageSubscription {
        guard stream == Self.changesStream else { throw PageError.unknownOp(stream) }
        // The last snapshot the page has: the state now, which it reads with `snapshot` as it subscribes,
        // shown or hidden; then each one this stream sent. Only a newer one is an event, and a show sends it.
        var sent = snapshot()
        let send: @MainActor () -> Void = { [weak self] in
            guard let self, isShown else { return }
            let next = snapshot()
            guard next != sent else { return }
            onEvent(next)
            sent = next
        }
        // task-owner: lives as long as the page's subscription; event-driven (Observation), no timer.
        // Hidden, the observed value is nil and reads only `isShown` (no row, no snapshot); shown, it is
        // the snapshot, so a change of any row wakes it.
        let task = Task { [weak self] in
            for await next in ObservationStream({ self.flatMap { $0.isShown ? $0.snapshot() : nil } }) {
                guard !Task.isCancelled else { return }
                if next != nil { send() }
            }
        }
        streams.append((task, send))
        return PageSubscription { task.cancel() }
    }

    /// The section's state now, as the page reads it.
    public func snapshot() -> JSONValue {
        let joined = dependencies.joined()
        var reply: [String: JSONValue] = [
            "rows": .array(dependencies.rows().map(Self.json)),
            "style": .string(dependencies.style().rawValue),
            "busy": .array((joined?.busy ?? []).sorted().map(JSONValue.string)),
            "failed": .object((joined?.failed ?? [:]).mapValues { .string($0.rawValue) }),
        ]
        if let open = joined?.openMenu { reply["openMenu"] = .string(open) }
        if let team = dependencies.cloudTeam() {
            reply["cloudTeam"] = .object(["name": .string(team.name), "personal": .bool(team.personal)])
        }
        return .object(reply)
    }

    /// One row as the page reads it (`MachineRow`).
    public static func json(_ row: MachineSectionRow) -> JSONValue {
        var fields: [String: JSONValue] = [
            "id": .string(row.id), "name": .string(row.name), "kind": .string(row.kind.rawValue),
            "isLocal": .bool(row.isLocal), "isConnected": .bool(row.isConnected), "isConnecting": .bool(row.isConnecting),
        ]
        if let state = row.serverState { fields["serverState"] = .string(state.rawValue) }
        if let health = row.health {
            let word: String = switch health {
            case .ok: "ok"
            case .warning: "warning"
            case .failing: "failing"
            }
            fields["health"] = .string(word)
        }
        if let step = row.healthStep { fields["healthStep"] = .string(step.rawValue) }
        if let machine = row.joined {
            var joined: [String: JSONValue] = ["id": .string(machine.id), "name": .string(machine.name), "state": .string(machine.state.rawValue)]
            if let platform = machine.platform { joined["platform"] = .string(platform) }
            if let mintedBy = machine.mintedBy { joined["mintedBy"] = .string(mintedBy) }
            fields["joined"] = .object(joined)
        }
        return .object(fields)
    }
}
