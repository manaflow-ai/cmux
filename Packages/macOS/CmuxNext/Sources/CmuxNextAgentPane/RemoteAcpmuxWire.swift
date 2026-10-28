public import Foundation
import CmuxNextCompat
import os

/// The wire of a chat whose acpmux runs on another machine: it answers the page's acpmux
/// JSON-RPC (already checked by ``AgentPaneTransport``) with typed calls on the owning session
/// daemon (``AgentSessionRemoteClient``), and turns the daemon's pushes back into acpmux
/// notifications, so the page's own connect, replay and reconnect logic runs unchanged.
///
/// Only the chat's own session is served: `initialize`, `_acpmux/status`, `_acpmux/watch` (that
/// one session and the chats it started there, `agent-session-children-v1`, read-only), `_acpmux/attach`, `_acpmux/events`, `_acpmux/detach`, `session/prompt` (text
/// blocks only), `session/cancel`, `_acpmux/permission_respond` and the folder trust question
/// (`acp.trust.get`/`acp.trust.set`, through the daemon's `agent-session-trust`, cx-1bhjj; the
/// relay already holds a set that trusts to the person's fresh gesture), and who is in the chat
/// (`_acpmux/typing` and `_acpmux/view` out, `_acpmux/presence` back, `agent-session-presence-v1`;
/// an observer never types). Every other method, and any
/// frame that names another session, is answered `remote.unsupported`: nothing on the other
/// machine changes a mode, reads a folder or spawns a process from here.
///
/// A new chat's wire (``init(start:)``) has no session yet: its page's first `session/new` (the
/// first send, cx-k21v) starts the chat on that machine through the host's start
/// (`agent-session-start`, policy `ask`) once, and the wire then serves that one session. No
/// session exists on the other machine before that send.
public nonisolated final class RemoteAcpmuxWire: AcpmuxPaneWire {
    /// JSON-RPC `code` and `data.code` of a refused method.
    public static let unsupportedCode = -32601
    public static let unsupported = "remote.unsupported"
    public static let readOnly = "agent_session.read_only"

    /// Starts a new chat on the other machine in `cwd` with `harness` (the page's `session/new`
    /// values; nil leaves the host's own choice) and answers its attachment and session.
    public typealias Start = @Sendable (_ cwd: String?, _ harness: String?) async throws
        -> (client: any AgentSessionRemoteClient, session: String)
    /// The trust of `cwd` on the other machine (acpmux's `acp.trust.get` reply), or with `level`
    /// the person's answer recorded there (`acp.trust.set`).
    public typealias Trust = @Sendable (_ cwd: String, _ level: String?, _ homeChosen: Bool) async throws -> Data
    /// The relay's mark on a Trust answer for a home folder the person chose there.
    public static let homeChosenParam = "cmuxHomeChosen"

    private struct State {
        var onFrame: (@Sendable (String) -> Void)?
        var onClose: (@Sendable (Int, String) -> Void)?
        var closed = false
        /// acpmux's id of the session (an attach page names it; the tab may hold a name).
        var resolved: String?
        /// The session's daemon attachment; nil until a new chat's start answered.
        var client: (any AgentSessionRemoteClient)?
        /// The session the tab shows (its store record, or the one this wire started).
        var session: String?
        /// A `session/new` is starting the chat (one at a time).
        var starting = false
    }

    private static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "agent-pane.remote")
    private let start: Start?
    private let trust: Trust?
    private let state: Mutex<State>

    /// The wire of the chat `session` (its store record), through `client`.
    public init(client: any AgentSessionRemoteClient, session: String, trust: Trust? = nil) {
        start = nil
        self.trust = trust
        state = Mutex(State(client: client, session: session))
    }

    /// The wire of a new chat that has no session yet: the page's first `session/new` runs `start`.
    public init(start: @escaping Start, trust: Trust? = nil) {
        self.start = start
        self.trust = trust
        state = Mutex(State())
    }

    public func open(onFrame: @escaping @Sendable (String) -> Void,
                     onClose: @escaping @Sendable (Int, String) -> Void) async throws {
        state.withLock { state in
            state.onFrame = onFrame
            state.onClose = onClose
        }
    }

    public func send(_ text: String, completion: @escaping @Sendable (Bool) -> Void) {
        guard !state.withLock({ $0.closed }),
              let frame = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
              let method = frame["method"] as? String else { return completion(false) }
        completion(true)
        let id = frame["id"].flatMap(Self.idText)
        let params = frame["params"] as? [String: Any] ?? [:]
        switch method {
        case "initialize":
            // `acp.trust.set` listed: the person answers the folder question here (acpmux never
            // lists it, so a remote browser's page still cannot).
            reply(id, ["protocolVersion": 1, "agentCapabilities": [String: Any](),
                       "_meta": ["acpmux": ["origin": "remote", "extensions": trust == nil ? [] : ["acp.trust.set"]]]])
        case "_acpmux/status":
            reply(id, ["peers": [Any]()])
        case "session/new":
            startChat(id, params)
        case "acp.trust.get", "acp.trust.set":
            let level = params["level"] as? String
            guard let trust, params["sessionId"] == nil || names(params["sessionId"]),
                  let cwd = params["cwd"] as? String, cwd.hasPrefix("/"), (method == "acp.trust.get") == (level == nil) else {
                return refuse(id, method)
            }
            // task-owner: one daemon call per trust question or answer; its reply ends it
            Task { [weak self] in
                do {
                    let answer = try await trust(cwd, level, params[Self.homeChosenParam] as? String == "true")
                    self?.emit(id.map { #"{"jsonrpc":"2.0","id":\#($0),"result":"# + String(decoding: answer, as: UTF8.self) + "}" })
                } catch {
                    let refused = error as? AgentSessionRemoteError
                    self?.fail(id, code: refused?.code ?? Self.unsupported, message: refused?.message ?? String(describing: error))
                }
            }
        case "session/cancel":
            guard !isReadOnly else { return refuseReadOnly(id, method) }
            run(id) { client in try await client.cancel(); return Data("{}".utf8) }
        case "_acpmux/detach":
            run(id) { client in await client.detach(); return Data("{}".utf8) }
        case "_acpmux/typing":
            guard !isReadOnly else { return refuseReadOnly(id, method) }
            guard names(params["sessionId"]), let on = params["on"] as? Bool else { return refuse(id, method) }
            run(id) { client in try await client.typing(on); return Data("{}".utf8) }
        case "_acpmux/view":
            guard names(params["sessionId"]), let visible = params["visible"] as? Bool else { return refuse(id, method) }
            run(id) { client in try await client.view(visible); return Data("{}".utf8) }
        case "_acpmux/watch" where state.withLock({ $0.client == nil }):
            // A new chat before its first send: no session on that machine yet.
            reply(id, ["sessions": [Any]()])
        case "_acpmux/watch", "_acpmux/attach", "_acpmux/events":
            guard method == "_acpmux/watch" || names(params["sessionId"]) else { return refuse(id, method) }
            let page = Self.page(params, method: method)
            run(id) { [weak self] client in
                guard let self else { throw AgentSessionRemoteError(code: Self.unsupported, message: "closed") }
                return try await self.page(method, page, client: client)
            }
        case "link.inspect":
            // Remote paths are classified by the host that owns the chat. Image paths are
            // deliberately marked readable so ReplyImage starts `image.load`; the local app
            // never probes or resolves the same spelling here. Ordinary path chips remain
            // outside this machine's roots and are shown as elsewhere/locked by the page.
            let paths = (params["paths"] as? [String] ?? []).reduce(into: [String: Any]()) { result, path in
                if Self.remoteImagePath(path) != nil { result[path] = ["place": "root", "folder": false] }
                else { result[path] = ["place": "outside", "folder": false] }
            }
            reply(id, ["paths": paths, "sites": [:], "policy": [
                "outsideRoots": "text", "remoteImages": "always", "clickFreeImageHosts": [String](),
            ]])
        case "session/prompt":
            guard !isReadOnly else { return refuseReadOnly(id, method) }
            guard names(params["sessionId"]), let text = Self.text(params["prompt"]) else { return refuse(id, method) }
            let prompt = ((params["_meta"] as? [String: Any])?["acpmux"] as? [String: Any])?["promptId"] as? String
                ?? UUID().uuidString.lowercased()
            let session = state.withLock { $0.session } ?? ""
            run(id) { [weak self] client in
                let accepted = try await client.prompt(id: prompt, text: text)
                let object = (try? JSONSerialization.jsonObject(with: accepted)) as? [String: Any] ?? [:]
                let turn = object["turn_id"] ?? NSNull()
                self?.notify("_acpmux/prompt_accepted", ["sessionId": session, "promptId": prompt, "turnId": turn,
                                                         "queued": object["queued"] ?? false])
                return Self.json(["_meta": ["acpmux": ["promptId": prompt, "turnId": turn]]])
            }
        case "image.load":
            guard let src = params["src"] as? String, let path = Self.remoteImagePath(src) else {
                return refuse(id, method)
            }
            // The bytes are read by the daemon attached to the chat's host. The local app never
            // resolves this path, so a same-named file on this Mac cannot leak into the reply.
            run(id) { client in
                let data = try await client.media(path: path)
                guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                      let encoded = object["data"] as? String,
                      let bytes = Data(base64Encoded: encoded),
                      case .success(let source) = await AgentPaneReplyImages.remote(bytes) else {
                    throw AgentSessionRemoteError(code: Self.unsupported, message: "the remote image could not be decoded")
                }
                return Self.json(AgentPaneReply.success(["src": source]))
            }
        case "_acpmux/permission_respond":
            guard !isReadOnly else { return refuseReadOnly(id, method) }
            guard names(params["sessionId"]), let permission = params["permissionId"] as? String,
                  let option = params["optionId"] as? String else { return refuse(id, method) }
            // The decision proof the host added (never the page): acpmux on that machine decides.
            let decision = (params["_meta"] as? [String: Any])?["acpmux"] as? [String: Any]
            let nonce = decision?["decisionNonce"] as? String, proof = decision?["personDecision"] as? String
            // A question's answers and annotations go along unchanged: that machine's acpmux checks
            // them and the proof over them (dropped, the answer was refused there, or counted
            // without the preview the person chose).
            let json = { (key: String) in
                params[key].flatMap { $0 is NSNull ? nil : $0 }
                    .flatMap { try? JSONSerialization.data(withJSONObject: $0, options: [.fragmentsAllowed]) }
            }
            let answers = json("answers"), annotations = json("annotations")
            run(id) { client in
                try await client.permission(id: permission, option: option, answers: answers, annotations: annotations,
                                            decisionNonce: nonce, personDecision: proof)
                return Data("{}".utf8)
            }
        default:
            refuse(id, method)
        }
    }

    public func cancel(code: Int, reason: String) {
        guard close(), let client = state.withLock({ $0.client }) else { return }
        // task-owner: ends the daemon attachment once; nothing waits on it
        Task { await client.close() }
    }

    public func loadRemoteImage(_ path: String) async throws -> Data {
        guard let client = state.withLock({ $0.client }) else {
            throw AgentSessionRemoteError(code: Self.unsupported, message: "the remote chat has no session")
        }
        return try await client.media(path: path)
    }

    // MARK: Start

    /// A new chat's `session/new` (its first send): starts the chat on that machine once and
    /// answers its session. Refused on a wire that already has a session, while a start runs, and
    /// for an adopt (an outside chat of this Mac never moves there). A refused start leaves no
    /// session, so the next send (a person's action) may start again; nothing retries by itself.
    private func startChat(_ id: String?, _ params: [String: Any]) {
        let acpmux = (params["_meta"] as? [String: Any])?["acpmux"] as? [String: Any]
        guard let start, acpmux?["adopt"] == nil, state.withLock({ state -> Bool in
            guard !state.closed, state.client == nil, !state.starting else { return false }
            state.starting = true
            return true
        }) else { return refuse(id, "session/new") }
        let cwd = (params["cwd"] as? String).flatMap { $0.hasPrefix("/") ? $0 : nil }
        let harness = (acpmux?["harness"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        // task-owner: the one start of this wire's chat; its reply ends it
        Task { [weak self] in
            do {
                let (client, session) = try await start(cwd, harness)
                guard let self else { await client.close(); return }
                let open = state.withLock { state -> Bool in
                    state.starting = false
                    guard !state.closed else { return false }
                    (state.client, state.session) = (client, session)
                    return true
                }
                // The page reconnects with a new wire, which finds the started chat.
                guard open else { await client.close(); return }
                reply(id, ["sessionId": session])
            } catch {
                self?.state.withLock { $0.starting = false }
                let refused = error as? AgentSessionRemoteError
                // An untrusted folder is the page's folder trust question (`trust.pending` and the
                // folder, as acpmux's own gate names it), answered here when the wire can.
                let question: [String: Any] = refused?.code == "agent_session.untrusted_folder" && self?.trust != nil
                    ? ["reason": "trust.pending", "cwd": refused?.folder ?? cwd ?? ""] : [:]
                self?.fail(id, code: refused?.code ?? Self.unsupported, message: refused?.message ?? String(describing: error), data: question)
            }
        }
    }

    // MARK: Pages

    /// `_acpmux/watch` lists this session (an attach of one record gives its summary) and the
    /// chats it started on that machine (the daemon's `agent-session-children`, which only ever
    /// names this session's descendants; none from an older daemon), so the chat's Subagents
    /// summary shows them; `_acpmux/attach` subscribes (again: the daemon only pages);
    /// `_acpmux/events` pages.
    private func page(_ method: String, _ page: AgentSessionPage, client: any AgentSessionRemoteClient) async throws -> Data {
        if method == "_acpmux/events" { return Self.withMore(try await client.events(page)) }
        let result = try await client.attach(page) { [weak self] event in self?.pushed(event) }
        let object = (try? JSONSerialization.jsonObject(with: result)) as? [String: Any] ?? [:]
        let summary = object["session"] as? [String: Any]
        if let resolved = summary?["sessionId"] as? String { state.withLock { $0.resolved = resolved } }
        guard method == "_acpmux/watch" else { return result }
        let listed = (try? await client.children()).flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
        let children = (listed?["sessions"] as? [[String: Any]] ?? []).filter { child in
            (child["sessionId"] as? String).map { !names($0) } ?? false
        }
        Self.noteLinks(children)
        var reply: [String: Any] = ["sessions": (summary.map { [$0] } ?? []) + children]
        // The session the tab is bound to on that machine now, by acpmux's id: the daemon attached
        // only the session its store records for this tab. The page may hold another name for it (a
        // tab that records a session name, or one rebound there since the page got its id), and
        // opens this one rather than calling the tab's chat missing (direct.ts `tabSession`).
        if let resolved = summary?["sessionId"] as? String, !resolved.isEmpty { reply["tabSessionId"] = resolved }
        return Self.json(reply)
    }

    /// The parents of the children the daemon listed or changed, for the sidebar's session tree
    /// and the Subagents rows' open (``RemoteAgentSessionLinks``).
    private static func noteLinks(_ summaries: [[String: Any]]) {
        guard !summaries.isEmpty, JSONSerialization.isValidJSONObject(summaries),
              let data = try? JSONSerialization.data(withJSONObject: summaries) else { return }
        // task-owner: one main-actor note of what the daemon answered; nothing waits on it
        Task { @MainActor in
            let copy = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] ?? []
            RemoteAgentSessionLinks.shared.note(copy)
        }
    }

    /// acpmux answers `hasMore`; the page's replay loop reads `more`, so both are set.
    private static func withMore(_ result: Data) -> Data {
        guard var object = (try? JSONSerialization.jsonObject(with: result)) as? [String: Any],
              object["more"] == nil else { return result }
        object["more"] = object["hasMore"] ?? false
        return json(object)
    }

    private static func page(_ params: [String: Any], method: String) -> AgentSessionPage {
        let number = { (key: String) -> UInt64? in (params[key] as? NSNumber)?.uint64Value }
        let kinds = (params["kinds"] as? [Any])?.compactMap { $0 as? String }
        if method == "_acpmux/watch" { return AgentSessionPage(limit: 1, kinds: ["transcript"]) }
        return AgentSessionPage(afterSeq: number("afterSeq"), beforeSeq: number("beforeSeq"),
                                limit: (params["limit"] as? NSNumber)?.intValue, kinds: kinds)
    }

    // MARK: Pushes

    private func pushed(_ event: AgentSessionRemoteEvent) {
        switch event {
        case .record(let data):
            guard let record = try? JSONSerialization.jsonObject(with: data) else { return }
            notify("_acpmux/event", record)
        case .permission(let data):
            guard let request = try? JSONSerialization.jsonObject(with: data) else { return }
            notify("_acpmux/permission_pending", request)
        case .changed(let data):
            guard let change = try? JSONSerialization.jsonObject(with: data) else { return }
            // A child's change (the daemon streams only this session's descendants): a new child
            // joins the chat's Subagents summary and the sidebar's tree.
            if let changed = change as? [String: Any], let session = changed["session"] as? [String: Any],
               let id = changed["sessionId"] as? String, !names(id) {
                Self.noteLinks([session])
            }
            notify("_acpmux/session_changed", change)
        case .presence(let data):
            // Only this chat's set (the daemon streams no other's).
            guard let presence = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  names(presence["sessionId"]) else { return }
            notify("_acpmux/presence", presence)
        case .closed(let reason):
            Self.logger.info("remote agent attachment ended reason=\(reason, privacy: .public)")
            // The page reconnects (a fresh wire and daemon connection) and replays from the
            // newest seq it holds; this attachment's connection ends now.
            guard close(), let client = state.withLock({ $0.client }) else { return }
            // task-owner: ends the ended attachment's daemon connection; nothing waits on it
            Task { await client.close() }
            state.withLock { $0.onClose }?(1012, reason)
        }
    }

    // MARK: Helpers

    /// Marks the wire closed; false when it already was.
    private func close() -> Bool {
        state.withLock { state in
            guard !state.closed else { return false }
            state.closed = true
            return true
        }
    }

    /// True when `value` names this chat's session (the tab's, or acpmux's id for it).
    private func names(_ value: Any?) -> Bool {
        guard let name = value as? String else { return false }
        return state.withLock { state in state.session != nil && (name == state.session || name == state.resolved) }
    }

    /// The text of a prompt made only of text blocks; nil for any other block.
    static func text(_ value: Any?) -> String? {
        guard let blocks = value as? [[String: Any]], !blocks.isEmpty else { return nil }
        var parts: [String] = []
        for block in blocks {
            guard block["type"] as? String == "text", let text = block["text"] as? String else { return nil }
            parts.append(text)
        }
        return parts.joined(separator: "\n\n")
    }

    private func run(_ id: String?, _ work: @escaping @Sendable (any AgentSessionRemoteClient) async throws -> Data) {
        // A new chat before its first send has no attachment: nothing to page, cancel or detach.
        guard let client = state.withLock({ $0.client }) else {
            return reply(id, [:])
        }
        // task-owner: one daemon call per page request; its reply ends it
        Task { [weak self] in
            do {
                let result = try await work(client)
                self?.emit(id.map { #"{"jsonrpc":"2.0","id":\#($0),"result":"# + String(decoding: result, as: UTF8.self) + "}" })
            } catch let error as AgentSessionRemoteError {
                self?.fail(id, code: error.code, message: error.message)
            } catch {
                self?.fail(id, code: Self.unsupported, message: String(describing: error))
            }
        }
    }

    private func refuse(_ id: String?, _ method: String) {
        fail(id, code: Self.unsupported, message: "\(method) is not available for a chat on another machine")
    }

    /// The remote media reader takes a path, not a URL decoration. Keep the extension check at
    /// this boundary because the page's `image.load` request is untrusted.
    private static func remoteImagePath(_ text: String) -> String? {
        guard AgentPaneReplyPaths.isImagePath(text) else { return nil }
        if text.lowercased().hasPrefix("file://"), let url = URL(string: text), url.isFileURL {
            let host = url.host(percentEncoded: false) ?? ""
            guard host.isEmpty || host == "localhost" else { return nil }
            return url.path(percentEncoded: false)
        }
        return text.split(maxSplits: 1, whereSeparator: { $0 == "?" || $0 == "#" }).first.map(String.init)
    }

    private func refuseReadOnly(_ id: String?, _ method: String) {
        fail(id, code: Self.readOnly, message: "\(method) is not available on a read-only agent session")
    }

    private var isReadOnly: Bool {
        state.withLock { $0.client?.isReadOnly ?? false }
    }

    private func fail(_ id: String?, code: String, message: String, data: [String: Any] = [:]) {
        guard let id else { return }
        let error: [String: Any] = ["code": Self.unsupportedCode, "message": message, "data": data.merging(["code": code]) { $1 }]
        emit(#"{"jsonrpc":"2.0","id":\#(id),"error":"# + String(decoding: Self.json(error), as: UTF8.self) + "}")
    }

    private func reply(_ id: String?, _ result: [String: Any]) {
        emit(id.map { #"{"jsonrpc":"2.0","id":\#($0),"result":"# + String(decoding: Self.json(result), as: UTF8.self) + "}" })
    }

    private func notify(_ method: String, _ params: Any) {
        emit(String(decoding: Self.json(["jsonrpc": "2.0", "method": method, "params": params]), as: UTF8.self))
    }

    private func emit(_ text: String?) {
        guard let text else { return }
        let onFrame = state.withLock { $0.closed ? nil : $0.onFrame }
        onFrame?(text)
    }

    /// A JSON-RPC id as its JSON text (number or string), so the reply carries the same id.
    private static func idText(_ value: Any) -> String? {
        guard JSONSerialization.isValidJSONObject([value]),
              let data = try? JSONSerialization.data(withJSONObject: [value]) else { return nil }
        return String(decoding: data.dropFirst().dropLast(), as: UTF8.self)
    }

    static func json(_ object: Any) -> Data {
        (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
    }
}

/// A refused daemon call: its stable `error_code` (`agent_session.*`) and text.
public nonisolated struct AgentSessionRemoteError: Error, Sendable, Equatable {
    public var code: String
    public var message: String
    /// The folder a refused start named (`agent_session.untrusted_folder`).
    public var folder: String?

    public init(code: String, message: String, folder: String? = nil) {
        self.code = code
        self.message = message
        self.folder = folder
    }
}
