import CmuxNextCompat
public import CmuxNextPages
public import CmuxNextSettings
public import Foundation

extension PageDescriptor {
    /// The server cards (webviews/src/pages/server-cards): cmux-page://cmux.server-cards/, one card
    /// per route in one floating ``WebCardPanel`` (and the server panel's routes in the menu bar
    /// item's popover). A new card adds its ops' prefix here.
    public static let serverCards = PageDescriptor(id: "cmux.server-cards", resource: "server-cards",
                                                   namespaces: ["cmux.card.", "cmux.pairInvite.", "cmux.addMachine.", "cmux.server."])
}

/// "Pair Another Machine…" on the server card page (`#/pair-invite`, webviews/src/pages/server-cards):
/// the reverse of Add Server. This Mac mints an invite (`server.pair.invite`) and watches its socket;
/// when a machine redeems the code the socket says `arrived` with that machine's pending server
/// pairing, and Add Server's own model (``approver``: the same preview and approve intents) reads its
/// facts and words, so no second approval path exists.
///
/// Swift keeps only what touches the system: the mint, the socket (its secret never reaches the
/// page), the approver, the clipboard. The page derives every step, button and the countdown from
/// `status` (webviews/src/pages/server-cards/pairInvite/model.ts):
/// - `status` → `{session, mint, failure?, invite?, frames, approver}`;
/// - `newCode` → a new invite (the person's own click or key);
/// - `copy {target}` → the code, the `cmux pair` line or the install line, concealed (the person's own click or key);
/// - `setRunChief {on}` → the approver's Chief option (the person's own click or key);
/// - `setName {name}` → the Name field, read when Confirm goes;
/// - SECURITY: Confirm and Try Again are not page ops. They are the panel's native control
///   (``PersonControl``, named here from the approver's step) over the slot the page leaves for it,
///   and only the person's own click on it approves (``personPressed()``): no key, script, MCP call
///   or page reaches it;
/// - stream `changes` → one empty event whenever `status` may have changed.
///
/// Event driven: the socket pushes every change; the countdown is the page's.
@MainActor
public final class PairInviteCardProvider: WebCard {
    public static let route = "pair-invite"
    static let statusOp = "cmux.pairInvite.status"
    static let newCodeOp = "cmux.pairInvite.newCode"
    static let copyOp = "cmux.pairInvite.copy"
    static let setRunChiefOp = "cmux.pairInvite.setRunChief"
    static let setNameOp = "cmux.pairInvite.setName"
    static let changesStream = "cmux.pairInvite.changes"

    public var card: String { Self.route }
    public var prefix: String { "cmux.pairInvite." }
    public weak var host: WebCardPanel?

    /// The mint's state: `idle` before an opening and after a close.
    enum Mint: String { case idle, minting, ready, failed }

    /// Add Server's own model: the preview, the words, the name and the approve.
    public let approver: ServerModel
    private let service: PairInviteService
    private let copyText: (String) -> Void
    private let qr: (String) -> String?
    private var generation = 0
    private(set) var mint = Mint.idle
    private(set) var failure: PairInviteFailure?
    private(set) var invite: PairInvite?
    /// The socket's frames for the current invite, in order (the page folds them into its phase).
    private(set) var frames: [PairInviteFrame] = []
    private var arrivedCode: String?
    /// The card's Name field, as the page last sent it (empty keeps the machine's own name).
    private var typedName: String?
    private var socket: Task<Void, Never>?
    private var listeners: [Int: @MainActor (JSONValue) -> Void] = [:]
    private var nextListener = 0

    /// - Parameters:
    ///   - copy: Writes one value to the clipboard (concealed: a single-use code).
    ///   - qr: The QR of a payload as a PNG data URL.
    public init(service: PairInviteService, approver: ServerModel, copy: @escaping (String) -> Void = { _ in },
                qr: @escaping (String) -> String? = { _ in nil }) {
        self.service = service
        self.approver = approver
        copyText = copy
        self.qr = qr
    }

    // Not an isolated deinit (cx-t7hu): the handle is Sendable and stops from any thread.
    nonisolated deinit {
        socket?.cancel()
    }

    /// Whether the socket still runs (tests check that close stops it).
    var isWatching: Bool { socket != nil }

    // MARK: - WebCard

    /// A card already showing a live invite keeps it; any other opening mints a new one.
    public func opened(again: Bool) {
        guard !again || mint == .idle else { return }
        // task-owner: one mint per opening; closed() or a newer mint supersedes it (its generation).
        Task { [weak self] in await self?.mintInvite() }
    }

    /// The card closed: the socket stopped, the approval dropped. A late mint or frame is dropped
    /// (generation). Closing never voids the code on the Worker; it expires on its own.
    public func closed() {
        generation += 1
        stopSocket()
        // A result from this opening never greets the next one.
        approver.dismissApproval()
        (mint, failure, invite, frames, arrivedCode, typedName) = (.idle, nil, nil, [], nil, nil)
        changed()
    }

    // MARK: - The invite

    /// Mints a new invite (the card opens, New Code). Any earlier one is dropped; the Worker voids
    /// it too (one live invite per user).
    func mintInvite() async {
        stopSocket()
        generation += 1
        let mine = generation
        // A new code starts clean: the last machine's result or refusal never shows on it.
        approver.dismissApproval()
        (mint, failure, invite, frames, arrivedCode, typedName) = (.minting, nil, nil, [], nil, nil)
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

    /// One frame from the invite's watch socket: kept for the page, and the approver told of an
    /// arrival. A frame that ends the invite stops the socket (an arrived machine's own pairing
    /// outlives it: Confirm still answers).
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

    // MARK: - Page ops

    public func call(_ op: String, params: JSONValue, context: PageCallContext) async throws -> JSONValue {
        switch op {
        case Self.statusOp:
            return status()
        case Self.newCodeOp:
            try Self.requireGesture(context)
            await mintInvite()
            return .null
        case Self.copyOp:
            try Self.requireGesture(context)
            // Only an unused invite that still runs shows its code; an ended one copies nothing.
            guard let invite, socket != nil, arrivedCode == nil, invite.expiresAt > Date() else {
                throw PageError.invalidParams("no invite shows")
            }
            switch params["target"]?.stringValue {
            case "code": copyText(invite.displayCode)
            case "line": copyText(invite.line)
            case "installLine": copyText(invite.installLine)
            default: throw PageError.invalidParams("target is code, line or installLine")
            }
            return .null
        case Self.setRunChiefOp:
            try Self.requireGesture(context)
            guard let on = params["on"]?.boolValue else { throw PageError.invalidParams("on is required") }
            approver.approval.runChief = on
            return .null
        case Self.setNameOp:
            typedName = params["name"]?.stringValue
            return .null
        default:
            throw PageError.unknownOp(op)
        }
    }

    /// SECURITY: the person clicked the native Confirm or Try Again (the panel checked the click).
    public func personPressed() {
        confirm(name: typedName)
    }

    /// The native click-only control for the approver's step: Confirm while the machine shows,
    /// Try Again after a refusal, none otherwise.
    var personControl: PersonControl? {
        switch approver.addServerStep {
        case .review: PersonControl(title: PairInviteCardStrings.confirm, isEnabled: approver.canApprove)
        case .approving: PersonControl(title: PairInviteCardStrings.confirm, isEnabled: false)
        case .approveFailed: PersonControl(title: ServerStrings.tryAgain, isEnabled: approver.canApprove)
        default: nil
        }
    }

    /// SECURITY: approves the arrived machine through Add Server's approve, once the approver can.
    /// `name` is the card's Name field (empty keeps the machine's own name).
    func confirm(name: String?) {
        switch approver.addServerStep {
        case .review, .approveFailed: guard approver.canApprove else { return }
        default: return
        }
        if let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty { approver.approval.name = trimmed }
        approver.approve()
    }

    private static func requireGesture(_ context: PageCallContext) throws {
        guard context.userGesture else {
            throw PageError(code: PageNativeOp.userOnlyCode, message: PairInviteCardStrings.clickOnly)
        }
    }

    public func subscribe(_ stream: String, filter: JSONValue, context: PageCallContext,
                          onEvent: @escaping @MainActor (JSONValue) -> Void) async throws -> PageSubscription {
        guard stream == Self.changesStream else { throw PageError.unknownOp(stream) }
        let id = nextListener
        nextListener += 1
        listeners[id] = onEvent
        // A page that subscribed after a change still reads the state it would have missed.
        onEvent(.object([:]))
        let approver = approver
        // task-owner: lives as long as the page's subscription; event-driven (Observation).
        let task = Task { [weak self] in
            var first = true
            for await _ in ObservationStream({ Self.fingerprint(approver) }) {
                guard !Task.isCancelled, let self else { return }
                // The first value is the state the page reads with `status`; only changes are events.
                if first { first = false } else { self.changed() }
            }
        }
        return PageSubscription { [weak self] in
            task.cancel()
            _ = self?.listeners.removeValue(forKey: id)
        }
    }

    /// Everything of the approver `status` reads.
    private static func fingerprint(_ approver: ServerModel) -> String {
        "\(approver.addServerStep)|\(approver.canApprove)|\(approver.approval.runChief)|\(approver.lastApproved ?? "")"
    }

    /// The card's state changed: the page reads `status` again, and a click begun before it redrew
    /// does not count as aimed at it.
    private func changed() {
        host?.rearm()
        host?.setPersonControl(personControl, card: card)
        for listener in listeners.values { listener(.object([:])) }
    }

    // MARK: - Status

    func status() -> JSONValue {
        var reply: [String: JSONValue] = [
            "session": JSONValue(generation),
            "mint": .string(mint.rawValue),
            "frames": .array(frames.map(Self.json)),
            "approver": approverJSON(),
        ]
        switch failure {
        case .signedOut?: reply["failure"] = ["signedOut": true]
        case let .refused(text)?: reply["failure"] = ["text": .string(text)]
        case nil: break
        }
        if let invite {
            var shown: [String: JSONValue] = [
                "code": .string(invite.displayCode), "line": .string(invite.line), "installLine": .string(invite.installLine),
                "expiresAt": JSONValue(Int((invite.expiresAt.timeIntervalSince1970 * 1000).rounded())),
            ]
            if let image = qr(invite.qrPayload) { shown["qr"] = .string(image) }
            reply["invite"] = .object(shown)
        }
        return .object(reply)
    }

    private static func json(_ frame: PairInviteFrame) -> JSONValue {
        switch frame {
        case .pending: ["t": "pending"]
        case let .arrived(code): ["t": "arrived", "code": .string(code)]
        case let .paired(host): ["t": "paired", "host": .string(host)]
        case .voided: ["t": "voided"]
        case .expired: ["t": "expired"]
        case .lost: ["t": "lost"]
        }
    }

    private func approverJSON() -> JSONValue {
        var out: [String: JSONValue] = [
            "canApprove": .bool(approver.canApprove), "runChief": .bool(approver.approval.runChief),
        ]
        if let last = approver.lastApproved { out["lastApproved"] = .string(last) }
        let step: String
        var candidate: PairingCandidate?
        var reject: String?
        switch approver.addServerStep {
        case .enterCode: step = "enterCode"
        case .lookingUp: step = "lookingUp"
        case let .codeRefused(text): (step, reject) = ("codeRefused", text)
        case let .review(found): (step, candidate) = ("review", found)
        case let .approving(found): (step, candidate) = ("approving", found)
        case let .approveFailed(found, text): (step, candidate, reject) = ("approveFailed", found, text)
        case let .added(name):
            step = "added"
            out["added"] = .string(name)
        }
        out["step"] = .string(step)
        if let candidate { out["candidate"] = Self.json(candidate) }
        if let reject { out["reject"] = .string(reject) }
        return .object(out)
    }

    private static func json(_ candidate: PairingCandidate) -> JSONValue {
        var out: [String: JSONValue] = [
            "code": .string(candidate.code), "name": .string(candidate.name), "os": .string(candidate.os),
            "version": .string(candidate.version), "words": .array(candidate.words.map { .string($0) }),
        ]
        if let region = candidate.region { out["region"] = .string(region) }
        return .object(out)
    }
}

/// The provider's own refusal (Resources/PairInvite.xcstrings).
enum PairInviteCardStrings {
    static var confirm: String {
        String(localized: "pairInvite.confirm", defaultValue: "Confirm", table: "PairInvite", bundle: .module)
    }

    static var clickOnly: String {
        String(localized: "pairInvite.confirmNote", defaultValue: "Click Confirm to pair it. Only a click pairs it, never a key or a script.",
               table: "PairInvite", bundle: .module)
    }
}
