public import Foundation
public import Observation

/// "Pair Another Machine…": the reverse of Add Server. This Mac mints an invite
/// (`server.pair.invite`), shows its code, its `cmux pair` line and a QR, and waits on the invite's
/// watch socket. When a machine redeems the code the socket says `arrived` with that machine's
/// pending server pairing, and the card runs Add Server's own preview and approve on it
/// (``approver``: the same `lookupCode` / `approveCode` intents), so no second approval path
/// exists. `voided` (a second machine used the code), the expiry and a lost socket each end the
/// invite and offer a new one.
///
/// Event driven: the socket pushes every change. The only repeating work is the one-second
/// countdown, which stops at expiry, on arrival, on the end of the invite and on close.
@MainActor @Observable
public final class PairInviteModel {
    public nonisolated enum Phase: Equatable, Sendable {
        case idle
        case minting
        /// The invite shows; no machine has used it yet.
        case waiting(PairInvite)
        /// A machine used it: its pending server pairing has `code` (the approver previews it).
        case arrived(PairInvite, code: String)
        /// The socket said the machine is enrolled (`paired {host}`).
        case paired(host: String)
        /// A second machine used the code: nothing pairs with it.
        case voided
        /// Ten minutes passed before a machine used it.
        case expired
        /// The socket closed before the invite ended.
        case lost
        case failed(PairInviteFailure)
    }

    /// What the card shows, derived from ``phase`` and the approver's Add Server step.
    public nonisolated enum Step: Equatable, Sendable {
        case minting
        case showing(PairInvite)
        /// The machine arrived; its facts and words are being read.
        case lookingUp(PairInvite)
        case review(PairInvite, PairingCandidate)
        case approving(PairInvite, PairingCandidate)
        case approveFailed(PairInvite, PairingCandidate, String)
        /// Enrolled: the machine's name (or the host id when the approve was not this card's).
        case paired(String)
        case voided
        case expired
        case lost
        case signedOut
        /// The mint or the preview was refused: the app's own sentence.
        case failed(String)
    }

    /// What the card's Copy buttons copy.
    public nonisolated enum CopyTarget: Equatable, Sendable {
        case code, line, installLine
    }

    public private(set) var phase: Phase = .idle
    /// The last thing copied (its button says Copied until the next invite).
    public private(set) var copied: CopyTarget?
    /// Now, as of the countdown's last tick.
    public private(set) var now: Date
    /// Add Server's own model: the preview, the words, the name and the approve.
    public let approver: ServerModel

    @ObservationIgnored private let service: PairInviteService
    @ObservationIgnored private let copyText: (String) -> Void
    @ObservationIgnored private let clock: @Sendable () -> Date
    @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var countdown: Task<Void, Never>?
    @ObservationIgnored private var socket: Task<Void, Never>?

    public init(service: PairInviteService, approver: ServerModel, copy: @escaping (String) -> Void = { _ in },
                clock: @escaping @Sendable () -> Date = { Date() },
                sleep: @escaping @Sendable (Duration) async throws -> Void = MachineJoinLineModel.taskSleep) {
        self.service = service
        self.approver = approver
        copyText = copy
        self.clock = clock
        self.sleep = sleep
        now = clock()
    }

    // Not an isolated deinit (cx-t7hu): each handle is Sendable and stops from any thread.
    nonisolated deinit {
        countdown?.cancel()
        socket?.cancel()
    }

    /// The invite shown now, while no machine has used it.
    public var invite: PairInvite? {
        if case let .waiting(invite) = phase { return invite }
        return nil
    }

    /// Seconds left on the shown invite, rounded up; nil when none shows.
    public var secondsLeft: Int? {
        guard let invite else { return nil }
        return max(0, Int(invite.expiresAt.timeIntervalSince(now).rounded(.up)))
    }

    /// Whether the socket or the countdown still runs (tests check that close stops both).
    public var isWatching: Bool { countdown != nil || socket != nil }

    public var step: Step {
        switch phase {
        case .idle, .minting: return .minting
        case let .waiting(invite): return .showing(invite)
        case let .arrived(invite, code):
            switch approver.addServerStep {
            case let .added(name): return .paired(name)
            case let .review(candidate) where candidate.code == code: return .review(invite, candidate)
            case let .approving(candidate) where candidate.code == code: return .approving(invite, candidate)
            case let .approveFailed(candidate, reject) where candidate.code == code: return .approveFailed(invite, candidate, reject)
            case let .codeRefused(reject): return .failed(reject)
            default: return .lookingUp(invite)
            }
        case let .paired(host):
            return .paired(approver.lastApproved ?? host)
        case .voided: return .voided
        case .expired: return .expired
        case .lost: return .lost
        case .failed(.signedOut): return .signedOut
        case let .failed(.refused(text)): return .failed(text)
        }
    }

    /// Whether Confirm can go: the arrived machine's facts and words show, and no approve is in flight.
    public var canConfirm: Bool {
        switch step {
        case .review, .approveFailed: approver.canApprove
        default: false
        }
    }

    /// Mints a new invite (the card opens, New Code). Any earlier one is dropped; the Worker voids
    /// it too (one live invite per user).
    public func mint() async {
        stop()
        generation += 1
        let mine = generation
        copied = nil
        approver.cancelApproval()
        phase = .minting
        let result = await service.mint()
        guard mine == generation else { return }
        switch result {
        case let .success(invite):
            now = clock()
            guard invite.expiresAt > now else { phase = .expired; return }
            phase = .waiting(invite)
            startCountdown(mine)
            startSocket(invite, mine)
        case let .failure(failure):
            phase = .failed(failure)
        }
    }

    /// One frame from the invite's watch socket.
    public func receive(_ frame: PairInviteFrame) {
        switch (frame, phase) {
        case let (.arrived(code), .waiting(invite)):
            // The countdown is the code's; once a machine used it, the approver's facts show instead.
            stopCountdown()
            phase = .arrived(invite, code: code)
            approver.beginApproval(code: code)
        case let (.arrived(code), .arrived(invite, current)) where code != current:
            phase = .arrived(invite, code: code)
            approver.beginApproval(code: code)
        case (.pending, _), (.arrived, _):
            break
        case let (.paired(host), .waiting), let (.paired(host), .arrived):
            stop()
            phase = .paired(host: host)
        case (.voided, .waiting), (.voided, .arrived):
            stop()
            approver.cancelApproval()
            phase = .voided
        case (.expired, .waiting):
            stop()
            phase = .expired
        case (.lost, .waiting):
            stop()
            phase = .lost
        case (.expired, .arrived), (.lost, .arrived):
            // The machine's own pairing outlives the invite: Confirm still answers it.
            stop()
        default:
            break
        }
    }

    /// The countdown's tick: moves `now`, and ends the invite at `expiresAt`.
    public func tick() {
        now = clock()
        guard let invite, invite.expiresAt <= now else { return }
        stop()
        phase = .expired
    }

    /// SECURITY: Approves the arrived machine through Add Server's approve. Only the card's panel
    /// calls this, from the person's own click on Confirm (``PairInviteCardPanel``); no action,
    /// script, MCP call or page reaches it. `name` is the card's Name field (empty keeps the
    /// machine's own name); it is read only here, so typing in it redraws nothing.
    func confirm(name: String? = nil) {
        guard canConfirm else { return }
        if let name {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { approver.approval.name = trimmed }
        }
        approver.approve()
    }

    /// Copies the code, the line or the install line of the shown invite.
    public func copy(_ target: CopyTarget) {
        guard let invite else { return }
        switch target {
        case .code: copyText(invite.displayCode)
        case .line: copyText(invite.line)
        case .installLine: copyText(invite.installLine)
        }
        copied = target
    }

    /// The card closed: back to idle, the socket and the countdown stopped. A late mint or frame is
    /// dropped (generation). Closing never voids the code on the Worker; it expires on its own.
    public func close() {
        generation += 1
        stop()
        approver.cancelApproval()
        phase = .idle
        copied = nil
    }

    private func stop() {
        stopCountdown()
        socket?.cancel()
        socket = nil
    }

    private func stopCountdown() {
        countdown?.cancel()
        countdown = nil
    }

    private func startCountdown(_ mine: Int) {
        let sleep = self.sleep
        // task-owner: the countdown; ends at expiry, on arrival, at the invite's end, on close and on a new mint.
        countdown = Task { [weak self] in
            // wakeup-allow: a visible countdown ("Expires in 9:41") changes every second while the card
            // shows an unused invite, so each step is a real change, never an idle wakeup. It runs at most
            // the invite's life (ten minutes) and ends at expiry, on arrival, on close and on a new mint.
            while !Task.isCancelled {
                // wakeup-allow: the same countdown's one-second step.
                do { try await sleep(.seconds(1)) } catch { return }
                guard let self, self.generation == mine else { return }
                self.tick()
            }
        }
    }

    private func startSocket(_ invite: PairInvite, _ mine: Int) {
        let frames = service.watch(invite)
        // task-owner: the watch socket; ends with the invite (stop()) or when the socket closes.
        socket = Task { [weak self] in
            for await frame in frames {
                guard let self, self.generation == mine else { return }
                self.receive(frame)
            }
            // The stream ended without saying why: the socket is gone.
            guard let self, self.generation == mine, !Task.isCancelled else { return }
            self.receive(.lost)
        }
    }
}
