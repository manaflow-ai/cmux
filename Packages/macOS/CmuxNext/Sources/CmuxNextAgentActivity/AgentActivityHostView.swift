public import AppKit
public import WebKit
import CmuxNextDesign

/// Hosts the Activity renderer in a web view while keeping socket and native
/// operation ownership in ``AgentActivityModel`` and its injected source.
public final class AgentActivityHostView: NSView {
    public let model: AgentActivityModel
    public let webView: WKWebView
    private let source: any AgentActivitySource

    /// Makes an Activity web view for a model and its native data source.
    public init(model: AgentActivityModel, source: any AgentActivitySource) {
        self.model = model
        self.source = source
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let bridge = AgentActivityBridge(model: model, source: source)
        model.layout = AgentActivityTunables.layout.value
        configuration.userContentController.addScriptMessageHandler(bridge, contentWorld: .page, name: AgentActivityBridge.handlerName)
        let webView = WKWebView(frame: .zero, configuration: configuration)
        self.webView = webView
        super.init(frame: .zero)
        webView.navigationDelegate = bridge
        webView.autoresizingMask = [.width, .height]
        webView.allowsBackForwardNavigationGestures = false
        webView.allowsLinkPreview = false
        if webView.responds(to: NSSelectorFromString("_setDrawsBackground:")) { webView.setValue(false, forKey: "drawsBackground") }
        #if DEBUG
        webView.isInspectable = true
        #endif
        bridge.view = self
        model.onChange = { [weak self] in self?.pushState() }
        addSubview(webView)
        if let page = Self.bundledPage { webView.loadFileURL(page, allowingReadAccessTo: page.deletingLastPathComponent()) }
    }

    /// Compatibility initializer for prototype snapshot callers.
    public convenience init(model: AgentActivityModel, layoutOverride: AgentActivityLayout? = nil) {
        if let layoutOverride { model.layout = layoutOverride }
        self.init(model: model, source: AgentActivityMockSource())
    }

    /// The bundled Activity page.
    public static var bundledPage: URL? { Bundle.module.url(forResource: "index", withExtension: "html", subdirectory: "agent-activity") }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override func layout() { super.layout(); webView.frame = bounds }

    private func pushState() {
        guard webView.url != nil else { return }
        let state = AgentActivityBridge.state(model)
        guard JSONSerialization.isValidJSONObject(state), let data = try? JSONSerialization.data(withJSONObject: state), let json = String(data: data, encoding: .utf8) else { return }
        webView.evaluateJavaScript("window.cmuxActivityReceive && window.cmuxActivityReceive(\(json));", completionHandler: nil)
    }
}

private final class AgentActivityBridge: NSObject, WKScriptMessageHandlerWithReply, WKNavigationDelegate {
    static let handlerName = "agentActivity"
    weak var view: AgentActivityHostView?
    let model: AgentActivityModel
    let source: any AgentActivitySource

    init(model: AgentActivityModel, source: any AgentActivitySource) { self.model = model; self.source = source }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) async -> (Any?, String?) {
        guard let body = message.body as? [String: Any], let method = body["method"] as? String else {
            return (["ok": false, "error": ["userMessage": "Invalid Activity request"]], nil)
        }
        return await reply(to: method, params: body["params"] as? [String: Any] ?? [:])
    }

    @MainActor
    private func reply(to method: String, params: [String: Any]) async -> (Any?, String?) {
        do {
            let value: Any
            switch method {
            case "ready": value = Self.state(model)
            case "select": model.select(session: params["id"] as? String); value = NSNull()
            case "filter": model.filter = params["value"] as? String ?? ""; value = NSNull()
            case "scrub": model.scrub(to: (params["seq"] as? NSNumber).map { $0.uint64Value }); value = NSNull()
            case "layout":
                if let raw = params["value"] as? String, let layout = AgentActivityLayout(rawValue: raw) { model.layout = layout }
                value = NSNull()
            case "follow":
                model.follow(Set((params["ids"] as? [String]) ?? [])); value = NSNull()
            case "perform":
                guard let op = Self.operation(params) else { throw AgentActivitySourceError.malformed }
                model.perform(op); value = NSNull()
            case "frame":
                guard let blob = params["blob"] as? String else { throw AgentActivitySourceError.malformed }
                let width = params["width"] as? Int ?? 1
                let height = params["height"] as? Int ?? 1
                value = try await Self.frameData(source: source, frame: AgentActivityFrameRef(blob: blob, width: width, height: height))
            default: throw AgentActivitySourceError.refused(method)
            }
            return (["ok": true, "value": value], nil)
        } catch {
            return (["ok": false, "error": ["userMessage": String(describing: error)]], nil)
        }
    }

    @MainActor static func state(_ model: AgentActivityModel) -> [String: Any] {
        var sessions: [String: [[String: Any]]] = [:]
        for (machine, values) in model.sessionsByMachine { sessions[machine] = values.map(session) }
        return ["sessionsByMachine": sessions, "machineNames": model.machineNames, "connections": model.connections.mapValues(connection), "eventsBySession": model.eventsBySession.mapValues { $0.map(event) }, "selectedSessionID": model.selectedSessionID as Any, "scrubSeq": model.scrubSeq as Any, "filter": model.filter, "watching": Array(model.watching), "layout": model.layout.rawValue, "strings": ["title": AgentActivityStrings.title, "filter": AgentActivityStrings.filter, "emptyTitle": AgentActivityStrings.emptyTitle, "emptyDetail": AgentActivityStrings.emptyDetail, "noFrame": AgentActivityStrings.noFrame, "active": AgentActivityStrings.status(.active), "idle": AgentActivityStrings.status(.idle), "paused": AgentActivityStrings.status(.paused), "live": AgentActivityStrings.live, "stop": AgentActivityStrings.stop, "pause": AgentActivityStrings.pause, "resume": AgentActivityStrings.resume, "watch": AgentActivityStrings.watch, "unwatch": AgentActivityStrings.watch]]
    }

    static func session(_ value: AgentActivitySession) -> [String: Any] { ["id": value.id, "machine": value.machine, "machineName": value.machineName, "label": value.label, "agentKind": value.agentKind, "agentName": value.agentName, "attribution": value.attribution.rawValue, "workspaceTitle": value.workspaceTitle as Any, "terminalTitle": value.terminalTitle as Any, "colorHex": value.colorHex, "targetApps": value.targetApps, "status": status(value.status), "startedAt": value.startedAt.timeIntervalSince1970 * 1000, "lastActionAt": value.lastActionAt.timeIntervalSince1970 * 1000, "endedAt": value.endedAt?.timeIntervalSince1970 as Any, "acts": value.acts, "observes": value.observes, "errors": value.errors, "foregroundOnly": value.foregroundOnly] }
    static func status(_ value: AgentActivityStatus) -> Any { switch value { case .active: return "active"; case .idle: return "idle"; case .paused: return "paused"; case .ended(let reason): return ["ended": reason.rawValue] } }
    static func connection(_ value: AgentActivityConnection) -> String { switch value { case .connected: return "connected"; case .notStarted: return "not_started"; case .notSetUp: return "not_set_up"; case .unreachable: return "unreachable" } }
    static func frame(_ value: AgentActivityFrameRef) -> [String: Any] { ["blob": value.blob, "width": value.width, "height": value.height, "expired": value.expired] }
    static func event(_ value: AgentActivityEvent) -> [String: Any] { ["seq": value.seq, "time": value.time.timeIntervalSince1970 * 1000, "kind": value.kind.rawValue, "tool": value.tool as Any, "target": value.target as Any, "ok": value.ok, "errorCode": value.errorCode as Any, "durationMs": value.durationMs as Any, "redactedTextLength": value.redactedTextLength as Any, "beforeFrame": value.beforeFrame.map(frame) as Any, "afterFrame": value.afterFrame.map(frame) as Any, "clickPoint": value.clickPoint.map { ["x": $0.x, "y": $0.y] } as Any] }
    static func json(_ object: [String: Any]) -> String { guard let data = try? JSONSerialization.data(withJSONObject: object), let value = String(data: data, encoding: .utf8) else { return "{}" }; return value }
    static func frameData(source: any AgentActivitySource, frame: AgentActivityFrameRef) async throws -> String {
        guard let image = await source.image(for: frame), let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff), let data = bitmap.representation(using: .png, properties: [:]) else {
            throw AgentActivitySourceError.malformed
        }
        return data.base64EncodedString()
    }
    static func operation(_ p: [String: Any]) -> AgentActivityUserOp? { guard let raw = p["op"] as? String else { return nil }; let session = p["session"] as? String; switch raw { case "stop": return session.map { .stop(session: $0) }; case "pause": return session.map { .pause(session: $0) }; case "resume": return session.map { .resume(session: $0) }; case "watch": return session.map { .watch(session: $0, on: p["on"] as? Bool ?? false) }; case "export": return session.map { .export(session: $0) }; case "openAgent": return session.map { .openAgent(session: $0) }; case "openTarget": return session.map { .openTarget(session: $0) }; case "stopAll": return (p["machine"] as? String).map { .stopAll(machine: $0) }; default: return nil } }
}
