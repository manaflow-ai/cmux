public import Foundation
public import Observation

/// Add Device's "Any machine: one line" way (Labs `labs.machineJoin`): mint a single-use line, show
/// it with a countdown, and flip to joined when a joined machine carrying its `joinTokenId` shows up
/// in `cmux machine list`.
///
/// The list is read once per trigger, never on a timer: when the line is shown, when the card gets
/// the focus (``refresh()``) and on each mesh change (``MachineJoinService/meshChanges``). The only
/// repeating work is the one-second countdown, which stops at expiry, on the flip and on close.
@MainActor @Observable
public final class MachineJoinLineModel {
    public nonisolated enum Phase: Equatable, Sendable {
        case idle
        case minting
        case showing(JoinLine)
        case joined(JoinLine, JoinedMachine)
        /// The line's time ran out before a machine joined with it. It is never shown again.
        case expired
        case failed(JoinLineFailure)
    }

    public private(set) var phase: Phase = .idle
    /// The optional name the line is minted with (the joined machine's name in the list). Not
    /// observed: the card's field writes it as the person types and must not redraw on each key.
    @ObservationIgnored public var name = ""
    /// The line was copied (the button says so until a new line).
    public private(set) var copied = false
    /// Now, as of the countdown's last tick.
    public private(set) var now: Date
    /// The joined machine's checks (`cmux machine doctor ID`), filled in after the flip.
    public private(set) var checks: [HostStepResult] = []

    @ObservationIgnored private let service: MachineJoinService
    @ObservationIgnored private let clock: @Sendable () -> Date
    @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var countdown: Task<Void, Never>?
    @ObservationIgnored private var mesh: Task<Void, Never>?

    public init(service: MachineJoinService, clock: @escaping @Sendable () -> Date = { Date() },
                sleep: @escaping @Sendable (Duration) async throws -> Void = MachineJoinLineModel.taskSleep) {
        self.service = service
        self.clock = clock
        self.sleep = sleep
        now = clock()
    }

    /// `Task.sleep(for:)`, the countdown's default sleep: a named function, not an async closure
    /// literal, as a default argument (crash ratchet, cx-bsue).
    @Sendable public nonisolated static func taskSleep(_ duration: Duration) async throws {
        // wakeup-allow: the visible countdown's one-second step (startCountdown), only while a line shows.
        try await Task.sleep(for: duration)
    }

    // Not an isolated deinit (cx-t7hu): each handle is Sendable and stops from any thread.
    nonisolated deinit {
        countdown?.cancel()
        mesh?.cancel()
    }

    /// The line shown now, while it still works.
    public var line: JoinLine? {
        if case let .showing(line) = phase { return line }
        return nil
    }

    /// Seconds left on the shown line, rounded up; nil when no line is shown.
    public var secondsLeft: Int? {
        guard let line else { return nil }
        return max(0, Int(line.expiresAt.timeIntervalSince(now).rounded(.up)))
    }

    /// Mints a new line (the way opens, New Line, Try Again). A line is never shown twice.
    public func mint() async {
        stop()
        generation += 1
        let mine = generation
        copied = false
        checks = []
        phase = .minting
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let result = await service.mint(trimmed.isEmpty ? nil : trimmed)
        guard mine == generation else { return }
        switch result {
        case let .success(line):
            now = clock()
            guard line.expiresAt > now else { phase = .expired; return }
            phase = .showing(line)
            startCountdown(mine)
            startMesh(mine)
            await refresh()
        case let .failure(failure):
            phase = .failed(failure)
        }
    }

    /// Reads the list once and flips to joined when a row carries the shown line's `joinTokenId`.
    /// The card's focus and each mesh change call it; it does nothing unless a line is shown.
    public func refresh() async {
        guard let line else { return }
        let mine = generation
        let rows = await service.list()
        guard mine == generation, case .showing = phase,
              let row = rows?.first(where: { $0.joinTokenId == line.joinTokenId }) else { return }
        stop()
        phase = .joined(line, row)
        let found = await service.doctor(row.id)
        guard mine == generation else { return }
        checks = found
    }

    /// The countdown's tick: moves `now`, and ends the line at `expiresAt`.
    public func tick() {
        now = clock()
        guard let line, line.expiresAt <= now else { return }
        stop()
        phase = .expired
    }

    /// Marks the line copied (the card's Copy Line copied it, concealed from clipboard managers).
    public func markCopied() {
        guard line != nil else { return }
        copied = true
    }

    /// The card closed: back to idle, the countdown and the mesh watch stopped. A late mint or
    /// read is dropped (generation).
    public func close() {
        generation += 1
        stop()
        phase = .idle
        copied = false
        checks = []
    }

    /// Whether the countdown or the mesh watch still runs (tests check that close stops both).
    public var isWatching: Bool { countdown != nil || mesh != nil }

    private func stop() {
        countdown?.cancel()
        countdown = nil
        mesh?.cancel()
        mesh = nil
    }

    private func startCountdown(_ mine: Int) {
        let sleep = self.sleep
        // task-owner: the countdown; ends at expiry, on the flip, on close and on a new mint (stop()).
        countdown = Task { [weak self] in
            // wakeup-allow: a visible countdown ("Expires in 9:41") changes every second while the card
            // shows an unexpired line, so each step is a real change, never an idle wakeup. It runs at
            // most the line's life (ten minutes) and ends at expiry, on the flip, on close and on a new mint.
            while !Task.isCancelled {
                // wakeup-allow: the same countdown's one-second step.
                do { try await sleep(.seconds(1)) } catch { return }
                guard let self, self.generation == mine else { return }
                self.tick()
            }
        }
    }

    private func startMesh(_ mine: Int) {
        let changes = service.meshChanges()
        // task-owner: the mesh watch; ends with the line (stop()) or when the stream ends.
        mesh = Task { [weak self] in
            for await _ in changes {
                guard let self, self.generation == mine else { return }
                await self.refresh()
            }
        }
    }
}
