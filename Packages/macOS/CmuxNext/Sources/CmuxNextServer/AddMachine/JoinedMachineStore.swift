public import Foundation
public import Observation
import CmuxNextWakeups

/// A Revoke or Rotate on a joined machine (a row shows the last one that failed).
public nonisolated enum JoinedMachineChange: String, Sendable {
    case revoke, rotate
}

/// The person's machines joined through the hub (a pair code or a one-line token), for the Machines
/// section. Read on a trigger: when the section shows, when Add Device's card reads the list (its
/// flip), after a Revoke or Rotate, and while a section shows (``startAging(_:visible:)``), once
/// when the first online row's heartbeat would pass ``JoinedMachine/onlineWindow``.
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

    /// The calls, nil while nobody is signed in (the store then lists nothing).
    @ObservationIgnored private let service: () -> MachineJoinService?
    /// The last read ticket handed out (``beginRead()``), and the newest one whose rows (or the
    /// switch turning off) the store shows. A read that started before the shown one is dropped.
    @ObservationIgnored private var issued = 0
    @ObservationIgnored private var shown = 0

    /// The one deadline that re-checks online rows (``startAging(_:visible:)``): it never repeats on its own.
    @ObservationIgnored private let ageTimer: DemandTimer
    /// The sections showing the rows (one per window), each saying whether it is still on screen.
    @ObservationIgnored private var watchers: [ObjectIdentifier: @MainActor () -> Bool] = [:]
    @ObservationIgnored private let clock: () -> Date

    public init(service: @escaping () -> MachineJoinService?, clock: @escaping () -> Date = { Date() },
                ageTimer: DemandTimer = DemandTimer(owner: "machines.joined.age")) {
        self.service = service
        self.clock = clock
        self.ageTimer = ageTimer
    }

    /// `owner`'s section shows the rows: while any section does, the store re-reads the list once
    /// when the first online row's heartbeat would pass ``JoinedMachine/onlineWindow`` (the hub's
    /// 90 s row TTL), and a row whose read failed goes offline at that moment. No online row with a
    /// heartbeat, no deadline. A fire finding no section still on screen (`visible` false) stops.
    public func startAging(_ owner: AnyObject, visible: @escaping @MainActor () -> Bool) {
        watchers[ObjectIdentifier(owner)] = visible
        scheduleAge()
    }

    /// `owner`'s section hid or closed; the deadline stops when no section shows the rows.
    public func stopAging(_ owner: AnyObject) {
        watchers[ObjectIdentifier(owner)] = nil
        if watchers.isEmpty { ageTimer.cancel() }
    }

    /// Whether a re-check deadline is pending (tests).
    public var isAging: Bool { ageTimer.isScheduled }

    /// Turns online rows whose heartbeat passed the window offline, at `now`.
    public func age(now: Date) {
        let next = machines.map { $0.aged(now: now) }
        if next != machines { machines = next }
    }

    private func scheduleAge() {
        guard !watchers.isEmpty, let due = JoinedMachine.nextExpiry(machines) else { return ageTimer.cancel() }
        // A second past the expiry, so the row has crossed the window when it is read; at least one second.
        let delay = max(1, due.timeIntervalSince(clock()) + 1)
        ageTimer.schedule(after: .milliseconds(Int(delay * 1000))) { @MainActor [weak self] in await self?.ageFired() }
    }

    /// The deadline: drop the sections no longer on screen, then read the list once and age what the
    /// read did not renew. The read (``finishRead(_:ticket:)``) sets the next deadline.
    func ageFired() async {
        watchers = watchers.filter { $0.value() }
        guard !watchers.isEmpty else { return }
        await refresh()
        age(now: clock())
        scheduleAge()
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
        scheduleAge()
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
