import CmuxNextCompat
public import CmuxNextPages
public import CmuxNextSettings
import Foundation

/// The Mac server's surfaces on the server page (webviews/src/pages/server-cards/server): the menu
/// bar panel (`#/server-panel`), Health (`#/server-health`) and the server's pairing code
/// (`#/server-pairing`) in the menu bar item's popover. One ``ServerModel`` owns the state (the
/// owner's snapshot, the intents in flight); the page draws it. Add Server is a native card on the
/// same model (``AddServerDialog``), and no page op adds a server.
///
/// - `status` → `{connection, snapshot?, chief?, lastReject?, pending}`;
/// - `send {kind, ...}` → null: SECURITY: turn the server on or off, Show Pairing Code, Fix and
///   Revoke go only with the person's own click or key in the page (the host's record, never the
///   page's word);
/// - stream `changes` → one empty event whenever `status` may have changed.
@MainActor
public final class ServerPageProvider: PageProvider {
    static let statusOp = "cmux.server.status"
    static let sendOp = "cmux.server.send"
    static let changesStream = "cmux.server.changes"

    public var prefix: String { "cmux.server." }

    public let model: ServerModel
    private let qr: (String) -> String?
    /// The refusal of a person-only change asked without the person's own click or key.
    private let personOnlyMessage: String
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

    // MARK: - Page ops

    public func call(_ op: String, params: JSONValue, context: PageCallContext) async throws -> JSONValue {
        switch op {
        case Self.statusOp:
            return status()
        case Self.sendOp:
            try requireGesture(context)
            model.send(try Self.intent(params))
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
    /// Primed now, in the subscribe's turn, so a change before the task first runs is an event.
    private func startWatch() {
        guard watch == nil else { return }
        let model = model
        let later = ObservationStream.current({ Self.fingerprint(model) }).later
        // task-owner: the pages' subscriptions; cancelled when the last one ends. Event-driven (Observation).
        watch = Task { [weak self] in
            for await _ in later {
                guard !Task.isCancelled, let self else { return }
                self.changed()
            }
        }
    }

    /// The state changed: the pages read `status` again.
    private func changed() {
        for listener in listeners.values { listener(.object([:])) }
    }

    /// Everything `status` reads.
    private static func fingerprint(_ model: ServerModel) -> String {
        "\(model.connection)|\(String(describing: model.snapshot))|\(String(describing: model.chief))|\(model.pending.map(\.key))"
            + "|\(model.lastReject ?? "")"
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
}
