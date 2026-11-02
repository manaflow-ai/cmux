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
    /// The machine whose more menu shows as open (the capture fixture's): its button shows lit.
    public var openMenu: String?

    /// The calls, nil while Labs `labs.machineJoin` is off (the store then lists nothing).
    @ObservationIgnored private let service: () -> MachineJoinService?
    /// The last read ticket handed out (``beginRead()``), and the newest one whose rows (or the
    /// switch turning off) the store shows. A read that started before the shown one is dropped.
    @ObservationIgnored private var issued = 0
    @ObservationIgnored private var shown = 0

    public init(service: @escaping () -> MachineJoinService?) {
        self.service = service
    }

    /// Reads `cmux machine list` once. With the switch off the list empties; a failed read keeps
    /// the rows it had, and a read the switch turned off during shows nothing.
    public func refresh() async {
        let ticket = beginRead()
        guard let service = service() else { finishRead([], ticket: ticket); return }
        guard let rows = await service.list() else { return }
        guard self.service() != nil else { finishRead([], ticket: beginRead()); return }
        finishRead(rows, ticket: ticket)
    }

    /// A ticket for a list read about to start (the store's own, or Add Device's card reading the
    /// same list). Take it before the read, and hand its rows to ``finishRead(_:ticket:)``.
    public func beginRead() -> Int {
        issued += 1
        return issued
    }

    /// Shows a read's rows unless a read that started later has already been shown: reads can land
    /// out of order, and an older one must not bring back rows a newer one dropped.
    public func finishRead(_ rows: [JoinedMachine], ticket: Int) {
        guard ticket > shown else { return }
        shown = ticket
        failed = [:]
        if rows != machines { machines = rows }
    }

    /// Shows `rows` now, over any read still in flight (fixtures and tests).
    public func apply(_ rows: [JoinedMachine]) {
        finishRead(rows, ticket: beginRead())
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
