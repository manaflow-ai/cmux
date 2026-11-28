public import Foundation
import Synchronization
import os

/// The wire of a chat whose acpmux runs on another machine: it answers the page's acpmux
/// JSON-RPC (already checked by ``AgentPaneTransport``) with typed calls on the owning session
/// daemon (``AgentSessionRemoteClient``), and turns the daemon's pushes back into acpmux
/// notifications, so the page's own connect, replay and reconnect logic runs unchanged.
///
/// Only the chat's own session is served: `initialize`, `_acpmux/status`, `_acpmux/watch` (that
/// one session), `_acpmux/attach`, `_acpmux/events`, `_acpmux/detach`, `session/prompt` (text
/// blocks only), `session/cancel` and `_acpmux/permission_respond`. Every other method, and any
/// frame that names another session, is answered `remote.unsupported`: nothing on the other
/// machine starts a session, changes a mode, reads a folder or spawns a process from here.
public nonisolated final class RemoteAcpmuxWire: AcpmuxPaneWire {
    /// JSON-RPC `code` and `data.code` of a refused method.
    public static let unsupportedCode = -32601
    public static let unsupported = "remote.unsupported"

    private struct State {
        var onFrame: (@Sendable (String) -> Void)?
        var onClose: (@Sendable (Int, String) -> Void)?
        var closed = false
        /// acpmux's id of the session (an attach page names it; the tab may hold a name).
        var resolved: String?
    }

    private static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "agent-pane.remote")
    private let client: any AgentSessionRemoteClient
    /// The session the tab shows (its store record).
    private let session: String
    private let state = Mutex(State())

    public init(client: any AgentSessionRemoteClient, session: String) {
        self.client = client
        self.session = session
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
            reply(id, ["protocolVersion": 1, "agentCapabilities": [String: Any](),
                       "_meta": ["acpmux": ["origin": "remote", "extensions": [String]()]]])
        case "_acpmux/status":
            reply(id, ["peers": [Any]()])
        case "session/cancel":
            run(id) { client in try await client.cancel(); return Data("{}".utf8) }
        case "_acpmux/detach":
            run(id) { client in await client.detach(); return Data("{}".utf8) }
        case "_acpmux/watch", "_acpmux/attach", "_acpmux/events":
            guard method == "_acpmux/watch" || names(params["sessionId"]) else { return refuse(id, method) }
            let page = Self.page(params, method: method)
            run(id) { [weak self] client in
                guard let self else { throw AgentSessionRemoteError(code: Self.unsupported, message: "closed") }
                return try await self.page(method, page, client: client)
            }
        case "session/prompt":
            guard names(params["sessionId"]), let text = Self.text(params["prompt"]) else { return refuse(id, method) }
            let prompt = ((params["_meta"] as? [String: Any])?["acpmux"] as? [String: Any])?["promptId"] as? String
                ?? UUID().uuidString.lowercased()
            let session = session
            run(id) { [weak self] client in
                let accepted = try await client.prompt(id: prompt, text: text)
                let object = (try? JSONSerialization.jsonObject(with: accepted)) as? [String: Any] ?? [:]
                let turn = object["turn_id"] ?? NSNull()
                self?.notify("_acpmux/prompt_accepted", ["sessionId": session, "promptId": prompt, "turnId": turn,
                                                         "queued": object["queued"] ?? false])
                return Self.json(["_meta": ["acpmux": ["promptId": prompt, "turnId": turn]]])
            }
        case "_acpmux/permission_respond":
            guard names(params["sessionId"]), let permission = params["permissionId"] as? String,
                  let option = params["optionId"] as? String else { return refuse(id, method) }
            run(id) { client in try await client.permission(id: permission, option: option); return Data("{}".utf8) }
        default:
            refuse(id, method)
        }
    }

    public func cancel(code: Int, reason: String) {
        guard close() else { return }
        let client = client
        // task-owner: ends the daemon attachment once; nothing waits on it
        Task { await client.close() }
    }

    // MARK: Pages

    /// `_acpmux/watch` lists only this session (an attach of one record gives its summary);
    /// `_acpmux/attach` subscribes (again: the daemon only pages); `_acpmux/events` pages.
    private func page(_ method: String, _ page: AgentSessionPage, client: any AgentSessionRemoteClient) async throws -> Data {
        if method == "_acpmux/events" { return Self.withMore(try await client.events(page)) }
        let result = try await client.attach(page) { [weak self] event in self?.pushed(event) }
        let object = (try? JSONSerialization.jsonObject(with: result)) as? [String: Any] ?? [:]
        let summary = object["session"] as? [String: Any]
        if let resolved = summary?["sessionId"] as? String { state.withLock { $0.resolved = resolved } }
        guard method == "_acpmux/watch" else { return result }
        return Self.json(["sessions": summary.map { [$0] } ?? []])
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
            notify("_acpmux/session_changed", change)
        case .closed(let reason):
            Self.logger.info("remote agent attachment ended reason=\(reason, privacy: .public)")
            // The page reconnects (a fresh wire and daemon connection) and replays from the
            // newest seq it holds; this attachment's connection ends now.
            guard close() else { return }
            let client = client
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
        return name == session || state.withLock { $0.resolved } == name
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
        let client = client
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

    private func fail(_ id: String?, code: String, message: String) {
        guard let id else { return }
        let error: [String: Any] = ["code": Self.unsupportedCode, "message": message, "data": ["code": code]]
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

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}
