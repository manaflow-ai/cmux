import CmuxFuzzSupport
import CmuxNextCompat
import Foundation
@testable import CmuxNextAgentPane

/// The relay and its observers as their doc comments describe them, kept beside the real ones while a
/// stream runs: which relay ids are open (``AcpmuxRequestIds``), which sessions are the pane's and their
/// folders (``AcpmuxPaneSessions``), the prompts acpmux accepted, each prompt's newest decision context
/// (``AcpmuxDecisionContexts``: an older `seq` never replaces a newer one) and the options that deny
/// (``AcpmuxPermissionOptions``: an option is a deny only when every sighting was `reject_*`).
nonisolated struct AgentStreamModel {
    nonisolated struct Context: Equatable {
        var seq: UInt64
        var nonce: String
        var instance: String
    }

    /// Whether the relay is a chat on another machine (the socket then reads `_acpmux/watch` tab sessions).
    let remote: Bool
    private var nextRelay = 1
    private var open: [Int: (raw: String, method: String)] = [:]
    private var begun: [Int] = []
    private var inFlight: Set<String> = []
    private var awaiting: Set<String> = []
    private(set) var sessions: Set<String> = []
    private(set) var folders: [String: String] = [:]
    private(set) var accepted: [String] = []
    private(set) var contexts: [String: Context] = [:]
    private(set) var localInstance: String?
    private(set) var denies: [String: [String: Bool]] = [:]
    /// Frames the relay drops (each one counted).
    private(set) var drops = 0

    init(remote: Bool) {
        self.remote = remote
    }

    // MARK: Generating

    /// `count` steps of a stream, each with what the relay does with it. `beginsFirst`: every begin and cancel
    /// comes before the first frame (a socket checks frames on its own queue, after the test pushed them all).
    /// `duplicates`: frames with two equal keys may come (they close a socket).
    mutating func steps(_ rng: inout FuzzRNG, count: Int, beginsFirst: Bool, duplicates: Bool) -> [AgentStreamStep] {
        var steps: [AgentStreamStep] = []
        var mark = 0
        if beginsFirst {
            for _ in 0..<rng.below(10) { steps.append(beginOrCancel(&rng)) }
        }
        while steps.count < count {
            if !beginsFirst, rng.oneIn(5) {
                steps.append(beginOrCancel(&rng))
                continue
            }
            mark += 1
            steps.append(frame(&rng, mark: mark, duplicates: duplicates))
        }
        return steps
    }

    private mutating func beginOrCancel(_ rng: inout FuzzRNG) -> AgentStreamStep {
        if !begun.isEmpty, rng.oneIn(5), let relayID = rng.element(of: begun) {
            if let entry = open.removeValue(forKey: relayID) { inFlight.remove(entry.raw) }
            return .cancel(relayID: relayID)
        }
        let key = rng.below(12)
        let raw = rng.oneIn(3) ? "\"p\(key)\"" : String(key)
        let method = rng.element(of: AgentStreamFrames.methods) ?? "session/new"
        let subject = method == AgentPaneAgentReply.method ? rng.element(of: AgentStreamFrames.sessions) : nil
        guard !inFlight.contains(raw) else { return .begin(raw: raw, method: method, subject: subject, relayID: nil) }
        let relayID = nextRelay
        nextRelay += 1
        open[relayID] = (raw, method)
        begun.append(relayID)
        inFlight.insert(raw)
        if AcpmuxPaneSessions.starting.contains(method) { awaiting.insert(raw) }
        return .begin(raw: raw, method: method, subject: subject, relayID: relayID)
    }

    private mutating func frame(_ rng: inout FuzzRNG, mark: Int, duplicates: Bool) -> AgentStreamStep {
        switch rng.below(16) {
        case 0..<5:
            let value = AgentStreamFrames.notification(&rng, mark: mark)
            observeNotification(value)
            return .frame(value.description, .page, value)
        case 5..<11:
            return reply(&rng)
        case 11, 12:
            // A frame cut or replaced by text that is no object.
            let source = AgentStreamFrames.notification(&rng, mark: mark).description
            drops += 1
            return .frame(AgentStreamFrames.notAnObject(source, &rng), .drop, nil)
        case 13 where duplicates:
            return .frame(AgentStreamFrames.duplicateKeys(&rng), .close, nil)
        default:
            // A reply with an id the relay never maps.
            let near = rng.element(of: begun) ?? 1
            let method = rng.element(of: AgentStreamFrames.methods) ?? "session/new"
            let value = AgentStreamFrames.reply(id: AgentStreamFrames.unusableID(near: near, &rng), method: method, &rng)
            drops += 1
            return .frame(value.description, .drop, value)
        }
    }

    /// A reply: to an open relay id three times in four, else to one answered, cancelled or never sent.
    private mutating func reply(_ rng: inout FuzzRNG) -> AgentStreamStep {
        let relayID: Int
        if !open.isEmpty, !rng.oneIn(4) {
            relayID = open.keys.sorted()[rng.below(open.count)]
        } else {
            relayID = rng.oneIn(2) ? (rng.element(of: begun) ?? nextRelay + 100) : nextRelay + 100 + rng.below(4)
        }
        let method = open[relayID]?.method ?? rng.element(of: AgentStreamFrames.methods) ?? "session/new"
        let value = AgentStreamFrames.reply(id: .int(Int64(relayID)), method: method, &rng)
        guard let entry = open.removeValue(forKey: relayID) else {
            drops += 1
            return .frame(value.description, .drop, value)
        }
        inFlight.remove(entry.raw)
        if entry.method == AgentPaneAgentReply.method { return .frame(value.description, .complete(raw: entry.raw), value) }
        observeReply(value, raw: entry.raw, method: entry.method)
        return .frame(value.description, .reply(raw: entry.raw), value)
    }

    // MARK: Observers

    /// A notification as the observers read it (its `method` and `params`).
    private mutating func observeNotification(_ value: FuzzJSON) {
        let method = value["method"]?.stringValue
        let params = value["params"]
        if method == "_acpmux/prompt_accepted", let promptId = params?["promptId"]?.stringValue { accepted.append(promptId) }
        switch method {
        case "_acpmux/permission_pending": request(params)
        case "_acpmux/event": event(params)
        default: break
        }
        if method == "_acpmux/event", let params, params.isObject { return record(params) }
        if method == "_acpmux/permission_pending", let params, let session = params["sessionId"]?.stringValue {
            note(session: session, params, seq: params["seq"]?.seqValue)
        }
    }

    /// A reply to `method`, its id the page's `raw`.
    private mutating func observeReply(_ value: FuzzJSON, raw: String, method: String) {
        let result = value["result"]
        // AcpmuxPermissionOptions: the history of `_acpmux/attach` and `_acpmux/events` replies.
        if AcpmuxPermissionOptions.historyReplies.contains(method), let events = result?["events"]?.arrayItems {
            for item in events { event(item) }
        }
        // AcpmuxPaneSessions: a starting request's reply names the pane's sessions, once.
        if let result, result.isObject, awaiting.remove(raw) != nil {
            for key in ["sessionId", "targetSessionId"] {
                if let session = result[key]?.stringValue { sessions.insert(session) }
            }
        }
        observeFolder(result, method: method)
        if remote, method == "_acpmux/watch", let tab = result?["tabSessionId"]?.stringValue, !tab.isEmpty { sessions.insert(tab) }
        // AcpmuxDecisionContexts: the run of `initialize`, then the records of history and snapshot replies.
        if method == AcpmuxPaneMethods.initialize {
            localInstance = result?["_meta"]?["acpmux"]?["personInstance"]?.stringValue
            return
        }
        if let result, result.isObject, ["_acpmux/attach", "_acpmux/watch", "_acpmux/events"].contains(method),
           let events = result["events"]?.arrayItems, events.allSatisfy(\.isObject) {
            for item in events { record(item) }
        }
    }

    private mutating func observeFolder(_ result: FuzzJSON?, method: String) {
        guard let result, result.isObject else { return }
        let session: FuzzJSON?
        let id: String?
        switch method {
        case "_acpmux/attach":
            session = result["session"]
            id = session?["sessionId"]?.stringValue
        case "session/new":
            session = result["_meta"]?["acpmux"]
            id = session?.isObject == true ? result["sessionId"]?.stringValue : nil
        default:
            return
        }
        guard let id, let cwd = session?["cwd"]?.stringValue, cwd.hasPrefix("/") else { return }
        folders[id] = cwd
    }

    /// AcpmuxPermissionOptions: a record's `request.options`.
    private mutating func request(_ record: FuzzJSON?) {
        guard let permission = record?["permissionId"]?.stringValue,
              let options = record?["request"]?["options"]?.arrayItems else { return }
        for option in options {
            guard let id = option["optionId"]?.stringValue, let kind = option["kind"]?.stringValue else { continue }
            denies[permission, default: [:]][id] = (denies[permission]?[id] ?? true) && kind.hasPrefix("reject")
        }
    }

    /// AcpmuxPermissionOptions: a `permission_request` record of acpmux's own.
    private mutating func event(_ value: FuzzJSON?) {
        guard value?["kind"]?.stringValue == "permission_request", value?["dir"]?.stringValue == "mux" else { return }
        request(value?["msg"])
    }

    /// AcpmuxDecisionContexts: a record of acpmux's own that names a prompt.
    private mutating func record(_ record: FuzzJSON) {
        guard record["dir"]?.stringValue == "mux", let kind = record["kind"]?.stringValue,
              kind == "permission_request" || kind == "permission_reissued",
              let session = record["sessionId"]?.stringValue, let message = record["msg"], message.isObject else { return }
        note(session: session, message, seq: record["seq"]?.seqValue)
    }

    private mutating func note(session: String, _ prompt: FuzzJSON, seq: UInt64?) {
        guard let permission = prompt["permissionId"]?.stringValue, let nonce = prompt["decisionNonce"]?.stringValue,
              let instance = prompt["personInstance"]?.stringValue, Self.isHex(nonce, count: 64), Self.isHex(instance, count: 32),
              !session.contains("\u{0}"), !permission.contains("\u{0}") else { return }
        let key = session + "\u{0}" + permission
        if let seq, let known = contexts[key]?.seq, seq < known { return }
        contexts[key] = Context(seq: seq ?? .max, nonce: nonce, instance: instance)
    }

    private static func isHex(_ text: String, count: Int) -> Bool {
        text.utf8.count == count && text.utf8.allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }
    }

    /// Whether a pane nobody sees gets the frame now (``AcpmuxPaneSocket/pageWaits(on:)``): any reply, an
    /// accepted prompt and a turn's end.
    static func pageWaits(_ value: FuzzJSON) -> Bool {
        if value["id"] != nil { return true }
        switch value["method"]?.stringValue {
        case "_acpmux/prompt_accepted": return true
        case "_acpmux/event": return ["turn_end", "turn_result"].contains(value["params"]?["kind"]?.stringValue ?? "")
        default: return false
        }
    }

    // MARK: Checking

    /// The observers hold what the model holds.
    func check(_ observers: AgentStreamObservers) throws {
        for session in AgentStreamFrames.sessions + [""] {
            try FuzzRun.check(observers.sessions.contains(session) == sessions.contains(session),
                              "session \(session.debugDescription): the pane's \(observers.sessions.contains(session)), model \(sessions)")
            try FuzzRun.check(observers.sessions.folder(of: session) == folders[session],
                              "folder of \(session.debugDescription): \(observers.sessions.folder(of: session) ?? "-"), model \(folders)")
            for permission in AgentStreamFrames.permissions {
                let context = observers.decisions.context(session: session, permission: permission)
                let expected = contexts[session + "\u{0}" + permission]
                try FuzzRun.check(context?.nonce == expected?.nonce && context?.instance == expected?.instance,
                                  "context of \(session.debugDescription)/\(permission): \(String(describing: context)), model \(String(describing: expected))")
            }
        }
        try FuzzRun.check(observers.decisions.localInstance == localInstance,
                          "local instance \(observers.decisions.localInstance ?? "-"), model \(localInstance ?? "-")")
        try FuzzRun.check(observers.accepted.values == accepted, "accepted prompts \(observers.accepted.values), model \(accepted)")
        for permission in AgentStreamFrames.permissions + ["zz"] {
            for option in AgentStreamFrames.optionIDs + ["zz"] {
                let known = denies[permission]?[option]
                try FuzzRun.check(observers.options.isDeny(permissionId: permission, optionId: option) == (known == true)
                                  && observers.options.isKnownAllow(permissionId: permission, optionId: option) == (known == false),
                                  "option \(permission)/\(option): deny \(observers.options.isDeny(permissionId: permission, optionId: option)), model \(String(describing: known))")
            }
        }
    }
}

/// The relay's request ids and the observers one connection's frames feed, as ``AcpmuxPaneSocket`` holds them.
nonisolated final class AgentStreamObservers: Sendable {
    /// The promptIds of the `_acpmux/prompt_accepted` frames, in order.
    nonisolated final class Accepted: Sendable {
        private let list = Mutex<[String]>([])

        func add(_ value: String) { list.withLock { $0.append(value) } }

        var values: [String] { list.withLock { $0 } }
    }

    let accepted: Accepted
    let ids: AcpmuxRequestIds
    let sessions = AcpmuxPaneSessions()
    let options = AcpmuxPermissionOptions()
    let decisions = AcpmuxDecisionContexts()

    init() {
        let accepted = Accepted()
        self.accepted = accepted
        ids = AcpmuxRequestIds(promptAccepted: { accepted.add($0) })
    }

    /// A begin or a cancel, as the transport makes it: the relay id, then the request noted as sent.
    func apply(_ step: AgentStreamStep) throws {
        switch step {
        case .begin(let raw, let method, let subject, let relayID):
            let got = ids.begin(pageID: raw, method: method, subject: subject)
            try FuzzRun.check(got == relayID, "begin \(raw) \(method): relay id \(String(describing: got)), model \(String(describing: relayID))")
            if got != nil { sessions.sent(method: method, id: raw) }
        case .cancel(let relayID):
            ids.cancel(relayID)
        case .frame:
            break
        }
    }

    /// The observers' pass over one frame for the page, as ``AcpmuxPaneSocket`` makes it.
    func observe(_ object: [String: Any], replyTo method: String?, remote: Bool) {
        options.observe(object, replyTo: method)
        sessions.observe(object)
        sessions.observeFolder(object, replyTo: method)
        if remote { sessions.observeTabSession(object, replyTo: method) }
        decisions.observe(object, replyTo: method)
    }
}
