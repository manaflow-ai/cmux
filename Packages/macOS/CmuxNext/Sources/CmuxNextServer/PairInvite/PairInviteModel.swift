import CmuxNextCompat
public import Foundation
import Observation

/// "Pair Another Machine…": the reverse of Add Server. This Mac mints an invite (`server.pair.invite`) and watches its
/// socket; when a machine redeems the code the socket says `arrived` with that machine's pending server pairing, and
/// Add Server's own model (``approver``: the same preview and approve intents) reads its facts and words, so no second
/// approval path exists. The card (``PairInviteDialog``) draws ``step(now:)``; this model holds the mint, the socket
/// (its secret never leaves it), the approver and the clipboard.
///
/// SECURITY: Confirm and Try Again are the card's person-only buttons: only the person's own click on one reaches
/// ``confirm(name:runChief:)`` (``CmuxDialogPersonClick``); no key, script or MCP call does.
///
/// Event driven: the socket pushes every change and the approver is observed; the countdown is the card's.
@MainActor
public final class PairInviteModel {
    /// The mint's state: `idle` before an opening and after a close.
    enum Mint: String { case idle, minting, ready, failed }

    /// What Copy puts on the clipboard.
    public enum CopyTarget: String, Sendable { case code, line, installLine }

    /// Add Server's own model: the preview, the words, the name and the approve.
    public let approver: ServerModel
    /// Told whenever ``step(now:)`` may have changed (a frame, the mint, the approver).
    var onChange: (@MainActor () -> Void)?
    private let service: PairInviteService
    private let copyText: (String) -> Void
    /// The QR of a payload as PNG data.
    let qr: (String) -> Data?
    private var generation = 0
    private(set) var mint = Mint.idle
    private(set) var failure: PairInviteFailure?
    private(set) var invite: PairInvite?
    /// The socket's frames for the current invite, in order (``step(now:)`` folds them into its phase).
    private(set) var frames: [PairInviteFrame] = []
    private var arrivedCode: String?
    private var socket: Task<Void, Never>?
    private var watching: Task<Void, Never>?

    /// - Parameters:
    ///   - copy: Writes one value to the clipboard (concealed: a single-use code).
    ///   - qr: The QR of a payload as PNG data.
    public init(service: PairInviteService, approver: ServerModel, copy: @escaping (String) -> Void = { _ in },
                qr: @escaping (String) -> Data? = { _ in nil }) {
        self.service = service
        self.approver = approver
        copyText = copy
        self.qr = qr
    }

    // Not an isolated deinit (cx-t7hu): the handles are Sendable and stop from any thread.
    nonisolated deinit {
        socket?.cancel()
        watching?.cancel()
    }

    /// Whether the socket still runs (tests check that close stops it).
    var isWatching: Bool { socket != nil }

    // MARK: - Opening and closing

    /// A card already showing a live invite keeps it; any other opening mints a new one. The approver is followed
    /// while the card shows.
    public func opened(again: Bool) {
        followApprover()
        guard !again || mint == .idle else { return }
        // task-owner: one mint per opening; closed() or a newer mint supersedes it (its generation).
        Task { [weak self] in await self?.mintInvite() }
    }

    /// The card closed: the socket stopped, the approval dropped. A late mint or frame is dropped (generation).
    /// Closing never voids the code on the Worker; it expires on its own.
    public func closed() {
        generation += 1
        stopSocket()
        watching?.cancel()
        watching = nil
        // A result from this opening never greets the next one.
        approver.dismissApproval()
        (mint, failure, invite, frames, arrivedCode) = (.idle, nil, nil, [], nil)
        changed()
    }

    // MARK: - The invite

    /// Mints a new invite (the card opens, New Code). Any earlier one is dropped; the Worker voids it too (one live
    /// invite per user).
    func mintInvite() async {
        stopSocket()
        generation += 1
        let mine = generation
        // A new code starts clean: the last machine's result or refusal never shows on it.
        approver.dismissApproval()
        (mint, failure, invite, frames, arrivedCode) = (.minting, nil, nil, [], nil)
        changed()
        let result = await service.mint()
        guard mine == generation else { return }
        switch result {
        case let .success(minted):
            (mint, invite) = (.ready, minted)
            if minted.expiresAt > Date() { startSocket(minted, mine) }
        case let .failure(refusal):
            (mint, failure) = (.failed, refusal)
        }
        changed()
    }

    /// New Code: the person's click or key on the card.
    public func newCode() {
        // task-owner: one mint per press; a newer mint or closed() supersedes it (its generation).
        Task { [weak self] in await self?.mintInvite() }
    }

    /// One frame from the invite's watch socket: kept for the card, and the approver told of an arrival. A frame
    /// that ends the invite stops the socket (an arrived machine's own pairing outlives it: Confirm still answers).
    func receive(_ frame: PairInviteFrame) {
        guard socket != nil else { return }
        switch frame {
        case .pending:
            return
        case let .arrived(code):
            guard code != arrivedCode else { return }
            arrivedCode = code
            approver.beginApproval(code: code)
        case .paired, .expired, .lost:
            stopSocket()
        case .voided:
            stopSocket()
            approver.cancelApproval()
        }
        frames.append(frame)
        changed()
    }

    private func startSocket(_ invite: PairInvite, _ mine: Int) {
        let stream = service.watch(invite)
        // task-owner: the watch socket; ends with the invite (stopSocket()) or when the socket closes.
        socket = Task { [weak self] in
            for await frame in stream {
                guard let self, self.generation == mine else { return }
                self.receive(frame)
            }
            // The stream ended without saying why: the socket is gone.
            guard let self, self.generation == mine, !Task.isCancelled else { return }
            self.receive(.lost)
        }
    }

    private func stopSocket() {
        socket?.cancel()
        socket = nil
    }

    /// Copies the code, the `cmux pair` line or the install line, concealed. Only an unused invite that still runs
    /// shows its code; an ended one copies nothing (false).
    @discardableResult
    public func copy(_ target: CopyTarget) -> Bool {
        guard let invite, socket != nil, arrivedCode == nil, invite.expiresAt > Date() else { return false }
        switch target {
        case .code: copyText(invite.displayCode)
        case .line: copyText(invite.line)
        case .installLine: copyText(invite.installLine)
        }
        return true
    }

    // MARK: - Confirm

    /// SECURITY: approves the arrived machine through Add Server's approve, once the approver can; only the person's
    /// own click on Confirm or Try Again calls it. `name` is the card's Name field (empty keeps the machine's own
    /// name); `runChief` its Chief option.
    public func confirm(name: String?, runChief: Bool?) {
        switch approver.addServerStep {
        case .review, .approveFailed: guard approver.canApprove else { return }
        default: return
        }
        if let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty { approver.approval.name = trimmed }
        if let runChief { approver.approval.runChief = runChief }
        approver.approve()
    }

    // MARK: - Changes

    /// Follows the approver while the card shows: its step, its approve, its Chief option.
    private func followApprover() {
        guard watching == nil else { return }
        let approver = approver
        // task-owner: lives while the card shows (closed() cancels it); event driven (Observation).
        watching = Task { [weak self] in
            var first = true
            for await _ in ObservationStream({ Self.fingerprint(approver) }) {
                guard !Task.isCancelled, let self else { return }
                // The first value is the state the card drew on opening; only changes redraw it.
                if first { first = false } else { self.changed() }
            }
        }
    }

    /// Everything of the approver ``step(now:)`` reads.
    private static func fingerprint(_ approver: ServerModel) -> String {
        "\(approver.addServerStep)|\(approver.canApprove)|\(approver.approval.runChief)|\(approver.lastApproved ?? "")"
    }

    private func changed() {
        onChange?()
    }
}
