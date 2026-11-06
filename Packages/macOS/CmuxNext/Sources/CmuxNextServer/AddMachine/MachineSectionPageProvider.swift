public import AppKit
import CmuxNextCompat
public import CmuxNextPages
public import CmuxNextSettings

public extension PageDescriptor {
    /// The right sidebar's Machines section (webviews/src/pages/machines): cmux-page://cmux.machines/.
    /// Its ops are its own (``MachineSectionPageProvider``); it runs no other app action.
    static let machines = PageDescriptor(id: "cmux.machines", resource: "machines", namespaces: [MachineSectionPageProvider.prefix])
}

/// Serves the Machines section page's `cmux.machines.*` ops from the machine registry, each
/// machine's last check, the person's hub-joined machines and the section's layout tunable:
/// - `snapshot` → `{rows, style, busy, failed, openMenu?}` (webviews/src/pages/machines/types.ts);
/// - stream `changes` → the whole snapshot each time it changes, only while the section shows: a
///   hidden section's page hears nothing, and the newest snapshot arrives when it shows again;
/// - `newWorkspace {machine}` → `workspace.newOnMachine`; `addMachine` → `device.add` (Add Device);
/// - `menu {row, menu, x, y}` → the registry's native menu for the row at the page point, answered
///   once it closes (`row`: New Workspace on This Machine; `joined`: Check, Rotate Credential, Revoke…).
/// The layout (groups, order, words) is the page's.
@MainActor
public final class MachineSectionPageProvider: PageProvider {
    public nonisolated static let prefix = "cmux.machines."
    static let snapshotOp = "cmux.machines.snapshot"
    static let changesStream = "cmux.machines.changes"
    static let newWorkspaceOp = "cmux.machines.newWorkspace"
    static let addMachineOp = "cmux.machines.addMachine"
    static let menuOp = "cmux.machines.menu"

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

        public init(rows: @escaping @MainActor () -> [MachineSectionRow], style: @escaping @MainActor () -> MachineSectionStyle,
                    joined: @escaping @MainActor () -> JoinedMachineStore?, newWorkspace: @escaping @MainActor (String) -> Bool,
                    addMachine: @escaping @MainActor () -> Bool, present: @escaping @MainActor (NSMenu, CGPoint) async -> Void,
                    menu: @escaping @MainActor (String, MachineSectionRow) -> NSMenu?) {
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
    var present: @MainActor (NSMenu, CGPoint) async -> Void
    private let dependencies: Dependencies
    /// Whether the section shows: the stream sends nothing while it is hidden.
    public private(set) var isShown = false
    /// Each live stream's sender; a change while hidden waits for the next show. A cancelled
    /// subscription's entry goes at the next show.
    private var streams: [(task: Task<Void, Never>, send: @MainActor () -> Void)] = []

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
            guard let machine = params["machine"]?.stringValue, !machine.isEmpty else { throw PageError.invalidParams("machine is required") }
            return ["ran": .bool(dependencies.newWorkspace(machine))]
        case Self.addMachineOp:
            return ["ran": .bool(dependencies.addMachine())]
        case Self.menuOp:
            guard let id = params["row"]?.stringValue, let kind = params["menu"]?.stringValue,
                  let row = dependencies.rows().first(where: { $0.id == id }) else {
                throw PageError.invalidParams("row is not a machine of the section")
            }
            guard let menu = dependencies.menu(kind, row) else { return .object([:]) }
            let point = CGPoint(x: params["x"]?.doubleValue ?? 0, y: params["y"]?.doubleValue ?? 0)
            await present(menu, point)
            return .object([:])
        default:
            throw PageError.unknownOp(op)
        }
    }

    public func subscribe(_ stream: String, filter: JSONValue, context: PageCallContext,
                   onEvent: @escaping @MainActor (JSONValue) -> Void) async throws -> PageSubscription {
        guard stream == Self.changesStream else { throw PageError.unknownOp(stream) }
        // The last snapshot the page has (from this stream or its own read); a show sends a newer one.
        var sent: JSONValue?
        let send: @MainActor () -> Void = { [weak self] in
            guard let self, isShown else { return }
            let next = snapshot()
            guard next != sent else { return }
            // The first value is the state the page reads with `snapshot`; only changes are events.
            if sent != nil { onEvent(next) }
            sent = next
        }
        // task-owner: lives as long as the page's subscription; event-driven (Observation), no timer.
        let task = Task { [weak self] in
            for await _ in ObservationStream({ self?.snapshot() }) {
                guard !Task.isCancelled else { return }
                send()
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
