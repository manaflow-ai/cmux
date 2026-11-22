import CmuxNextDaemon
import Foundation
import Synchronization

/// A scripted daemon that serves the state resources (`session.events`
/// with `extra.state`) next to a one-workspace tree, and records every v2
/// request. `state` is the JSON of `extra.state` (lists left out are empty);
/// `entities` adds `workspaces`/`tabs`/`terminals` arrays to the snapshot.
nonisolated final class StateDaemon: Sendable {
    static let workspaceKey = "0b8a2f1e-5a51-4c55-9f0e-6e2f6a4f9c01"

    final class Log: Sendable {
        let entries = Mutex<[[String: JSONValue]]>([])
    }

    let log = Log()
    let socket: ScriptedDaemonSocket

    var requests: [[String: JSONValue]] { log.entries.withLock { $0 } }

    /// The v2 operations received, in order.
    var operations: [String] { requests.compactMap { $0["operation"]?.stringValue } }

    func params(of operation: String) -> [String: JSONValue]? {
        guard case .object(let params)? = requests.last(where: { $0["operation"]?.stringValue == operation })?["params"] else { return nil }
        return params
    }

    init(state: String, entities: String = "", tabs: String = #"{"surface":1,"kind":"pty","tab_resource_id":"tab_a","terminal_resource_id":"term_a","title":"a"}"#,
         capabilities: [String] = [],
         failure: @escaping @Sendable (String) -> String? = { _ in nil },
         reply: @escaping @Sendable (String, [String: JSONValue]) -> String = { _, _ in "{}" }) throws {
        let log = log
        socket = try ScriptedDaemonSocket(handler: { request in
            if request["protocol"]?.stringValue == "cmux.protocol/2" {
                log.entries.withLock { $0.append(request) }
                let id = request["id"]?.stringValue ?? ""
                let operation = request["operation"]?.stringValue ?? ""
                var params: [String: JSONValue] = [:]
                if case .object(let object)? = request["params"] { params = object }
                if operation == "session.events" {
                    let stream = params["stream_id"]?.stringValue ?? "stream_x"
                    let extra = entities.isEmpty ? "" : entities + ","
                    let snapshot = #"{"protocol":"cmux.protocol/2","type":"stream_item","stream_id":"\#(stream)","sequence":"1","item":{"kind":"snapshot","cursor":{"generation":"g","revision":"1"},"snapshot":{\#(extra)"cursor":{"generation":"g","revision":"1"},"extra":{"state":\#(state)}}}}"#
                    return [#"{"protocol":"cmux.protocol/2","type":"response","id":"\#(id)","ok":true,"result":{"stream_id":"\#(stream)"}}"#, snapshot]
                }
                // A failure is a protocol/2 error object: `{"code", "message", "details"?, "retryable"}`.
                if let error = failure(operation) {
                    return [#"{"protocol":"cmux.protocol/2","type":"response","id":"\#(id)","ok":false,"error":\#(error)}"#]
                }
                let value = reply(operation, params)
                return [#"{"protocol":"cmux.protocol/2","type":"response","id":"\#(id)","ok":true,"result":{"value":\#(value),"generation":"g","revision":"2","replayed":false}}"#]
            }
            let id = request["id"]?.doubleValue.map { Int($0) } ?? 0
            switch request["cmd"]?.stringValue {
            case "identify":
                let caps = (DaemonCapabilities.shared.required + [DaemonCapabilities.shared.stateResources] + capabilities).map { "\"\($0)\"" }.joined(separator: ",")
                return [#"{"id":\#(id),"ok":true,"data":{"app":"cmux-tui","version":"0.1.0","protocol":12,"capabilities":[\#(caps)],"session":"local","pid":7,"registry_id":"r","generation":"g1","workspace_revision":1}}"#]
            case "list-workspaces":
                return [#"{"id":\#(id),"ok":true,"data":{"generation":"g1","registry_id":"r","workspace_revision":1,"workspaces":[{"id":1,"key":"\#(Self.workspaceKey)","name":"w","resource_id":"ws_w","screens":[{"id":4,"resource_id":"screen_s","layout":{"type":"leaf","pane":3},"panes":[{"id":3,"resource_id":"pane_p","active_tab":0,"tabs":[\#(tabs)]}]}]}]}}"#]
            default:
                return [#"{"id":\#(id),"ok":true,"data":{}}"#]
            }
        })
    }

    func connection() -> DaemonConnection {
        DaemonConnection(endpoint: DaemonEndpoint(socketPath: socket.path),
                         configuration: .init(terminalEnvironment: nil, sessionEvents: true))
    }

    func stop() { socket.stop() }
}
