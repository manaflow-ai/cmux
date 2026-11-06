import CmuxNextCompat
public import CmuxNextPages
public import CmuxNextSettings
import Foundation

/// The Mac server's surfaces on the server card page (webviews/src/pages/server-cards/server): the
/// menu bar panel (`#/server-panel`), Health (`#/server-health`) and the server's pairing code
/// (`#/server-pairing`) in the menu bar item's popover, and the Add Server card (`#/add-server`) in
/// the floating card panel. One ``ServerModel`` owns the state (the owner's snapshot, the intents in
/// flight, the Add Server draft); the page draws it and derives every layout, button and key.
///
/// - `status` → `{connection, snapshot?, chief?, lastReject?, pending, approver}`;
/// - `send {kind, ...}` → null: SECURITY: turn the server on or off, Show Pairing Code, Fix and
///   Revoke go only with the person's own click or key in the page (the host's record, never the
///   page's word);
/// - `approver.setCode|setName|setTeam {...}` → null: the Add Server draft (a complete code is
///   looked up, which changes nothing);
/// - `approver.setRunChief {on}` → null: the person's own click or key;
/// - `approver.approve {name?}` → null: SECURITY: adds the found server to the person's team, only
///   from the person's own click on the card's Approve (``WebCardPanel/isPersonClick(_:)``), once
///   the model can approve;
/// - `approver.cancel` → null: Cancel or Deny: the draft and the last answer go;
/// - stream `changes` → one empty event whenever `status` may have changed.
@MainActor
public final class ServerPageProvider: WebCard {
    public static let route = "add-server"
    static let statusOp = "cmux.server.status"
    static let sendOp = "cmux.server.send"
    static let setCodeOp = "cmux.server.approver.setCode"
    static let setNameOp = "cmux.server.approver.setName"
    static let setTeamOp = "cmux.server.approver.setTeam"
    static let setRunChiefOp = "cmux.server.approver.setRunChief"
    static let approveOp = "cmux.server.approver.approve"
    static let cancelOp = "cmux.server.approver.cancel"
    static let changesStream = "cmux.server.changes"

    public var card: String { Self.route }
    public var prefix: String { "cmux.server." }
    public weak var host: WebCardPanel?

    public let model: ServerModel
    private let qr: (String) -> String?
    /// The refusal of a person-only change asked without the person's own click or key.
    private let personOnlyMessage: String
    /// Counts the Add Server card's openings: the page starts its own field state per opening.
    private(set) var session = 0
    private var listeners: [Int: @MainActor (JSONValue) -> Void] = [:]
    private var nextListener = 0
    private var watch: Task<Void, Never>?

    /// - Parameters:
    ///   - qr: The QR code of a payload as a PNG data URL (dark on white).
    ///   - personOnlyMessage: The refusal of a person-only change without the person's own click or key.
    public init(model: ServerModel, personOnlyMessage: String, qr: @escaping (String) -> String? = { _ in nil }) {
        self.model = model
        self.personOnlyMessage = personOnlyMessage
        self.qr = ServerPageProvider.lastOnly(qr)
    }

    // Not an isolated deinit (cx-t7hu): the handle is Sendable and cancels from any thread.
    nonisolated deinit {
        watch?.cancel()
    }

    // MARK: - WebCard

    /// The Add Server card opens: a new opening starts clean in the page (the model already began).
    public func opened(again: Bool) {
        if !again { session += 1 }
        changed()
    }

    /// The card closed any way but its Cancel: the draft stays, as a reopening looks it up again.
    public func closed() {}

    // MARK: - Page ops

    public func call(_ op: String, params: JSONValue, context: PageCallContext) async throws -> JSONValue {
        switch op {
        case Self.statusOp:
            return status()
        case Self.sendOp:
            try requireGesture(context)
            model.send(try Self.intent(params))
        case Self.setCodeOp:
            guard let code = params["code"]?.stringValue else { throw PageError.invalidParams("code is required") }
            model.setApprovalCode(code)
        case Self.setNameOp:
            guard let name = params["name"]?.stringValue else { throw PageError.invalidParams("name is required") }
            model.approval.name = name
        case Self.setTeamOp:
            guard let team = params["team"]?.stringValue, model.candidate?.teams.contains(where: { $0.id == team }) == true else {
                throw PageError.invalidParams("team is one of the found server's teams")
            }
            model.approval.team = team
        case Self.setRunChiefOp:
            try requireGesture(context)
            guard let on = params["on"]?.boolValue else { throw PageError.invalidParams("on is required") }
            model.approval.runChief = on
        case Self.approveOp:
            // SECURITY: adds a server to the person's team: only their own click on the card's
            // Approve (WebCardPanel.isPersonClick), as Pair Another Machine's Confirm; no key,
            // script, MCP call or page reaches it.
            guard host?.isPersonClick(context) == true else {
                throw PageError(code: PageNativeOp.userOnlyCode, message: personOnlyMessage)
            }
            approve(name: params["name"]?.stringValue)
        case Self.cancelOp:
            model.dismissApproval()
        default:
            throw PageError.unknownOp(op)
        }
        return .null
    }

    public func subscribe(_ stream: String, filter: JSONValue, context: PageCallContext,
                          onEvent: @escaping @MainActor (JSONValue) -> Void) async throws -> PageSubscription {
        guard stream == Self.changesStream else { throw PageError.unknownOp(stream) }
        let id = nextListener
        nextListener += 1
        listeners[id] = onEvent
        startWatch()
        return PageSubscription { [weak self] in
            guard let self else { return }
            self.listeners[id] = nil
            if self.listeners.isEmpty {
                self.watch?.cancel()
                self.watch = nil
            }
        }
    }

    /// One observation of the model for every page that listens; it ends with the last listener.
    private func startWatch() {
        guard watch == nil else { return }
        let model = model
        // task-owner: the pages' subscriptions; cancelled when the last one ends. Event-driven (Observation).
        watch = Task { [weak self] in
            var first = true
            for await _ in ObservationStream({ Self.fingerprint(model) }) {
                guard !Task.isCancelled, let self else { return }
                // The first value is the state the pages read with `status`; only changes are events.
                if first { first = false } else { self.changed() }
            }
        }
    }

    private func changed() {
        for listener in listeners.values { listener(.object([:])) }
    }

    /// Everything `status` reads.
    private static func fingerprint(_ model: ServerModel) -> String {
        "\(model.connection)|\(String(describing: model.snapshot))|\(String(describing: model.chief))|\(model.pending.map(\.key))"
            + "|\(model.lastReject ?? "")|\(model.lastApproved ?? "")|\(String(describing: model.candidate))|\(model.approval)"
    }

    /// SECURITY: adds the found server once the model can; `name` is the card's Name field (empty
    /// keeps the draft's).
    func approve(name: String?) {
        if let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty { model.approval.name = trimmed }
        model.approve()
    }

    private func requireGesture(_ context: PageCallContext) throws {
        guard context.userGesture else {
            throw PageError(code: PageNativeOp.userOnlyCode, message: personOnlyMessage)
        }
    }

    /// The page's `send` intent.
    static func intent(_ params: JSONValue) throws -> ServerIntentKind {
        func text(_ key: String) throws -> String {
            guard let value = params[key]?.stringValue, !value.isEmpty else { throw PageError.invalidParams("\(key) is required") }
            return value
        }
        switch params["kind"]?.stringValue {
        case "setEnabled":
            guard let on = params["on"]?.boolValue else { throw PageError.invalidParams("on is required") }
            return .setEnabled(on)
        case "showPairingCode": return .showPairingCode
        case "fixCheck": return .fixCheck(HealthCheckID(try text("check")))
        case "revokeDevice": return .revokeDevice(try text("device"))
        default: throw PageError.invalidParams("kind is setEnabled, showPairingCode, fixCheck or revokeDevice")
        }
    }

    /// The last payload's image only: a snapshot repeats its offer on every read, and a new code replaces the old.
    private static func lastOnly(_ qr: @escaping (String) -> String?) -> (String) -> String? {
        var last: (payload: String, image: String?)?
        return { payload in
            if let last, last.payload == payload { return last.image }
            let image = qr(payload)
            last = (payload, image)
            return image
        }
    }

    // MARK: - Status

    func status() -> JSONValue {
        var reply: [String: JSONValue] = [
            "connection": ServerWire.connection(model.connection),
            "pending": pendingJSON(),
            "approver": approverJSON(),
        ]
        if let snapshot = model.snapshot { reply["snapshot"] = ServerWire.snapshot(snapshot, qr: qr) }
        if let chief = model.chief { reply["chief"] = ServerWire.chief(chief) }
        if let reject = model.lastReject { reply["lastReject"] = .string(reject) }
        return .object(reply)
    }

    /// The intents in flight the page marks: the switch, Show Pairing Code, each Fix and Revoke.
    private func pendingJSON() -> JSONValue {
        var switching = false, pairing = false
        var fixing: [JSONValue] = [], revoking: [JSONValue] = []
        for intent in model.pending {
            switch intent.kind {
            case .setEnabled: switching = true
            case .showPairingCode: pairing = true
            case let .fixCheck(check): fixing.append(.string(check.rawValue))
            case let .revokeDevice(device): revoking.append(.string(device))
            case .lookupCode, .approveCode: break
            }
        }
        return ["switching": .bool(switching), "pairing": .bool(pairing), "fixing": .array(fixing), "revoking": .array(revoking)]
    }

    private func approverJSON() -> JSONValue {
        var draft: [String: JSONValue] = [
            "code": .string(model.approval.code), "name": .string(model.approval.name), "runChief": .bool(model.approval.runChief),
        ]
        if let team = model.approval.team { draft["team"] = .string(team) }
        var out: [String: JSONValue] = [
            "session": JSONValue(session), "canApprove": .bool(model.canApprove), "draft": .object(draft),
        ]
        var candidate: PairingCandidate?
        switch model.addServerStep {
        case .enterCode: out["step"] = "enterCode"
        case .lookingUp: out["step"] = "lookingUp"
        case let .codeRefused(text): (out["step"], out["reject"]) = ("codeRefused", .string(text))
        case let .review(found): (out["step"], candidate) = ("review", found)
        case let .approving(found): (out["step"], candidate) = ("approving", found)
        case let .approveFailed(found, text): (out["step"], candidate, out["reject"]) = ("approveFailed", found, .string(text))
        case let .added(name): (out["step"], out["added"]) = ("added", .string(name))
        }
        if let candidate { out["candidate"] = ServerWire.candidate(candidate) }
        return .object(out)
    }
}
