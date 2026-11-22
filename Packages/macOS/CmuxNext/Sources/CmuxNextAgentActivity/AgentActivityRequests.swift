public import AppKit
public import Foundation

/// The Activity page's requests and state, for whichever host shows the page: the page asks
/// `ready`, `select`, `filter`, `scrub`, `open`, `layout`, `follow`, `perform` and `frame` (a `data:` URL of
/// the host's stored bytes, `size` `thumb` or `full`), and gets the model's state after each change. Operations stay with ``AgentActivityModel`` and its source.
@MainActor
public struct AgentActivityRequests {
    /// The model the page shows and drives.
    public let model: AgentActivityModel
    /// The source frames are read from.
    public let source: any AgentActivitySource

    /// - Parameters:
    ///   - model: The model the page shows and drives.
    ///   - source: The source frames are read from.
    public init(model: AgentActivityModel, source: any AgentActivitySource) {
        self.model = model
        self.source = source
    }

    /// Answers one page request (`method`, `params`) as `{ok: true, value}` or
    /// `{ok: false, error: {userMessage}}`.
    ///
    /// - Parameters:
    ///   - method: `ready`, `select`, `filter`, `scrub`, `open`, `layout`, `follow`, `perform` or `frame`.
    ///   - params: The request's JSON object.
    /// - Returns: The reply object.
    public func reply(to method: String, params: [String: Any]) async -> [String: Any] {
        // One tuple return after the do/catch: Swift 6.3 and 6.4 at -O drop the first element of
        // a tuple returned from both an awaiting `do` and its `catch` (swiftlang/swift#92698, cx-21wc5).
        let body: [String: Any]
        do {
            let value: Any
            switch method {
            case "ready": value = state()
            case "select": model.select(session: params["id"] as? String); value = NSNull()
            case "filter": model.filter = params["value"] as? String ?? ""; value = NSNull()
            case "scrub": model.scrub(to: (params["seq"] as? NSNumber).map { $0.uint64Value }); value = NSNull()
            case "open":
                // A frame clicked in the timeline or grid: its session, then that frame, in one turn.
                model.select(session: params["id"] as? String)
                model.scrub(to: (params["seq"] as? NSNumber).map { $0.uint64Value }); value = NSNull()
            case "layout":
                if let raw = params["value"] as? String, let layout = AgentActivityLayout(rawValue: raw) { model.layout = layout }
                value = NSNull()
            case "follow":
                model.follow(Set((params["ids"] as? [String]) ?? [])); value = NSNull()
            case "perform":
                guard let op = Self.operation(params) else { throw AgentActivitySourceError.malformed }
                try await model.performAndWait(op); value = NSNull()
            case "frame":
                guard let blob = params["blob"] as? String else { throw AgentActivitySourceError.malformed }
                let session = params["session"] as? String
                let requested = AgentActivityFrameSize(rawValue: params["size"] as? String ?? "") ?? .thumb
                let recording = session.flatMap { id in model.allSessions.first { $0.id == id }?.recording }
                let frame = AgentActivityFrameRef(blob: blob, width: params["width"] as? Int ?? 0,
                                                  height: params["height"] as? Int ?? 0)
                guard let data = await source.frame(frame, size: AgentActivityWire.frameSize(requested: requested, recording: recording),
                                                    session: session) else { throw AgentActivitySourceError.malformed }
                value = data.dataURL
            default: throw AgentActivitySourceError.refused(method)
            }
            body = ["ok": true, "value": value]
        } catch {
            body = ["ok": false, "error": ["userMessage": String(describing: error)]]
        }
        return body
    }

    /// The page's whole state (sessions, events, selection, filter, layout, strings).
    public func state() -> [String: Any] {
        var sessions: [String: [[String: Any]]] = [:]
        for (machine, values) in model.sessionsByMachine { sessions[machine] = values.map(Self.session) }
        return ["sessionsByMachine": sessions, "machineNames": model.machineNames, "connections": model.connections.mapValues(Self.connection), "eventsBySession": model.eventsBySession.mapValues { $0.map(Self.event) }, "selectedSessionID": model.selectedSessionID as Any, "scrubSeq": model.scrubSeq as Any, "filter": model.filter, "watching": Array(model.watching), "layout": model.layout.rawValue, "strings": AgentActivityStrings.page]
    }


    static func session(_ value: AgentActivitySession) -> [String: Any] { ["id": value.id, "machine": value.machine, "machineName": value.machineName, "label": value.label, "agentKind": value.agentKind, "agentName": value.agentName, "attribution": value.attribution.rawValue, "workspaceTitle": value.workspaceTitle as Any, "terminalTitle": value.terminalTitle as Any, "colorHex": value.colorHex, "targetApps": value.targetApps, "status": status(value.status), "startedAt": value.startedAt.timeIntervalSince1970 * 1000, "lastActionAt": value.lastActionAt.timeIntervalSince1970 * 1000, "endedAt": value.endedAt?.timeIntervalSince1970 as Any, "acts": value.acts, "observes": value.observes, "errors": value.errors, "foregroundOnly": value.foregroundOnly] }
    static func status(_ value: AgentActivityStatus) -> Any { switch value { case .active: return "active"; case .idle: return "idle"; case .paused: return "paused"; case .ended(let reason): return ["ended": reason.rawValue] } }
    static func connection(_ value: AgentActivityConnection) -> String { switch value { case .connected: return "connected"; case .notStarted: return "not_started"; case .notSetUp: return "not_set_up"; case .unreachable: return "unreachable" } }
    static func frame(_ value: AgentActivityFrameRef) -> [String: Any] { ["blob": value.blob, "width": value.width, "height": value.height, "expired": value.expired] }
    static func event(_ value: AgentActivityEvent) -> [String: Any] { ["seq": value.seq, "time": value.time.timeIntervalSince1970 * 1000, "kind": value.kind.rawValue, "tool": value.tool as Any, "target": value.target as Any, "ok": value.ok, "errorCode": value.errorCode as Any, "durationMs": value.durationMs as Any, "redactedTextLength": value.redactedTextLength as Any, "beforeFrame": value.beforeFrame.map(frame) as Any, "afterFrame": value.afterFrame.map(frame) as Any, "clickPoint": value.clickPoint.map { ["x": $0.x, "y": $0.y] } as Any] }
    static func json(_ object: [String: Any]) -> String { guard let data = try? JSONSerialization.data(withJSONObject: object), let value = String(data: data, encoding: .utf8) else { return "{}" }; return value }
    static func operation(_ p: [String: Any]) -> AgentActivityUserOp? { guard let raw = p["op"] as? String else { return nil }; let session = p["session"] as? String; switch raw { case "stop": return session.map { .stop(session: $0) }; case "pause": return session.map { .pause(session: $0) }; case "resume": return session.map { .resume(session: $0) }; case "watch": return session.map { .watch(session: $0, on: p["on"] as? Bool ?? false) }; case "export": return session.map { .export(session: $0) }; case "openAgent": return session.map { .openAgent(session: $0) }; case "openTarget": return session.map { .openTarget(session: $0) }; case "stopAll": return (p["machine"] as? String).map { .stopAll(machine: $0) }; default: return nil } }
}
