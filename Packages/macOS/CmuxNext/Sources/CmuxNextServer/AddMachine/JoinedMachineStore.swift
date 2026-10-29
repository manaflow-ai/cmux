public import Foundation
public import Observation

/// A Revoke or Rotate on a joined machine (a row shows the last one that failed).
public nonisolated enum JoinedMachineChange: String, Sendable {
    case revoke, rotate
}

/// The machines that joined the team with a one-line token, for the Machines section (Labs
/// `labs.machineJoin`). Read once per trigger, never on a timer: at launch, when the section shows,
/// when Add Device's card reads the list (its flip), and after a Revoke or Rotate.
@MainActor @Observable
public final class JoinedMachineStore {
    public typealias Change = JoinedMachineChange

    public private(set) var machines: [JoinedMachine] = []
    /// The ids with a Revoke or Rotate in flight (their menu items are off meanwhile).
    public private(set) var busy: Set<String> = []
    /// The last Revoke or Rotate that failed, by machine id, until the next read.
    public private(set) var failed: [String: Change] = [:]
    /// The machine whose "…" menu is open: its button stays shown and lit until the menu closes.
    public var openMenu: String?

    /// Marks `id`'s menu open, or closed when it is still the open one (another may have opened since).
    public func menuShown(_ id: String, _ open: Bool) {
        if open { openMenu = id } else if openMenu == id { openMenu = nil }
    }

    /// The calls, nil while Labs `labs.machineJoin` is off (the store then lists nothing).
    @ObservationIgnored private let service: () -> MachineJoinService?
    @ObservationIgnored private var generation = 0

    public init(service: @escaping () -> MachineJoinService?) {
        self.service = service
    }

    /// Reads `cmux machine list` once. With the switch off the list empties; a failed read keeps
    /// the rows it had.
    public func refresh() async {
        generation += 1
        let mine = generation
        guard let service = service() else { machines = []; return }
        let rows = await service.list()
        guard mine == generation, let rows else { return }
        apply(rows)
    }

    /// Takes rows another reader got (Add Device's card reads the same list). A read of the store's
    /// own still in flight is superseded by them.
    public func apply(_ rows: [JoinedMachine]) {
        generation += 1
        failed = [:]
        if rows != machines { machines = rows }
    }

    /// Revokes or rotates `id`, then reads the list again. False when the platform refused or the
    /// run failed (the row says so).
    @discardableResult
    public func perform(_ change: Change, _ id: String) async -> Bool {
        guard let service = service(), !busy.contains(id) else { return false }
        busy.insert(id)
        // Busy until the read after it lands, so a second click cannot start another meanwhile.
        defer { busy.remove(id) }
        failed[id] = nil
        let ok = switch change {
        case .revoke: await service.revoke(id)
        case .rotate: await service.rotate(id)
        }
        await refresh()
        if !ok { failed[id] = change }
        return ok
    }
}
