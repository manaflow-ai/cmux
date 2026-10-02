public import CmuxNextBrowser
public import Foundation
public import WebKit

/// The WebKit driver: implements the driver protocol
/// (plans/cmux-next/browser-repl/driver-protocol.md) on the App's `WebKitTab`s
/// for the Rust browser host. Behaviors ported from the #15570 Swift driver
/// (`WebKitBrowserReplDriver`): native AppKit input so events are trusted,
/// the `cmux-agent` content world with closed-shadow access, the frame
/// registry, load states, capture. Written new for cmux-next.
///
/// Policy, secrets and masking are the host's; the driver never sees a
/// secret handle (the host resolves it before a call reaches here).
@MainActor
public final class WebKitDriver: DriverCallHandler {
    public let events: AsyncStream<DriverEvent>
    let emitter: AsyncStream<DriverEvent>.Continuation
    weak var provider: (any AutomationTabProvider)?
    /// The page agent install source from the host (`hello.ack agent_bundle`).
    public var agentBundle: String?
    var sessions: [BrowserTabID: TabSession] = [:]

    public init(provider: any AutomationTabProvider, agentBundle: String? = nil) {
        self.provider = provider
        self.agentBundle = agentBundle
        (events, emitter) = AsyncStream.makeStream(of: DriverEvent.self, bufferingPolicy: .bufferingOldest(8192))
    }

    isolated deinit {
        emitter.finish()
    }

    public func call(method: String, params json: DriverJSON) async throws(DriverError) -> DriverJSON {
        let params = try DriverParams(method: method, json: json)
        switch method {
        case "tabs.list": return try tabsList(params)
        case "tabs.open": return try await tabsOpen(params)
        case "tabs.close": return try tabsClose(params)
        case "tabs.activate", "tab.bringToFront": return try tabsActivate(params)
        case "tab.info": return try tabInfo(params)
        case "tab.navigate": return try await tabNavigate(params)
        case "tab.history": return try await tabHistory(params)
        case "tab.reload": return try await tabReload(params)
        case "frames.list": return try await framesList(params)
        case "frame.evaluate": return try await frameEvaluate(params)
        case "input.mouse": return try await inputMouse(params)
        case "input.key": return try await inputKey(params)
        case "input.insertText": return try await inputInsertText(params)
        case "tab.screenshot": return try await tabScreenshot(params)
        case "tab.pdf": return try await tabPDF(params)
        case "cookies.get": return try await cookiesGet(params)
        case "cookies.clear": return try await cookiesClear(params)
        default: throw DriverError(.unsupported, "Unsupported driver method \(method)")
        }
    }

    func emit(_ name: String, _ payload: [String: DriverJSON]) {
        emitter.yield(DriverEvent(name: name, payload: .object(payload)))
    }

    /// The tab a call names, attached on first use.
    func target(_ params: DriverParams) throws(DriverError) -> (WebKitTab, TabSession) {
        let raw = try params.string("targetId")
        guard let entry = provider?.automationTabs(all: true).first(where: { $0.tab.id.rawValue == raw }) else {
            throw DriverError(.notFound, "\(params.method): no tab \(raw)")
        }
        return (entry.tab, session(for: entry.tab))
    }

    func session(for tab: WebKitTab) -> TabSession {
        if let existing = sessions[tab.id] { return existing }
        let session = TabSession(tabID: tab.id, driver: self)
        AgentWorld.install(into: tab.webView.configuration.userContentController, agentBundle: agentBundle,
                           handler: session.messages)
        sessions[tab.id] = session
        return session
    }

    /// A load-state message from a frame of a driven tab.
    func received(_ state: LoadState, url: String, title: String?, isMainFrame: Bool, tabID: BrowserTabID) {
        guard isMainFrame, let session = sessions[tabID] else { return }
        session.lastTitle = title
        session.waits.signal(state)
        if state == .commit {
            session.agentReady = false
            emit("tab.navigated", ["targetId": .string(tabID.rawValue), "url": .string(url),
                                   "frameId": session.frames.mainFrameID.map(DriverJSON.string) ?? .null,
                                   "sameDocument": .bool(false)])
        } else {
            emit("tab.loadState", ["targetId": .string(tabID.rawValue), "state": .string(state.name)])
        }
    }

    /// Stops driving every tab: removes the driver's scripts and fails waits.
    public func detach() {
        for (id, session) in sessions {
            session.waits.failAll(DriverError(.closed, "the session ended"))
            if let tab = provider?.automationTabs(all: true).first(where: { $0.tab.id == id })?.tab {
                let controller = tab.webView.configuration.userContentController
                controller.removeScriptMessageHandler(forName: AgentWorld.loadStateHandler, contentWorld: AgentWorld.world)
                // No per-world removal API: keep every script that is not ours.
                let ours: Set<String> = [AgentWorld.loadStateSource, agentBundle ?? ""]
                let keep = controller.userScripts.filter { !ours.contains($0.source) }
                controller.removeAllUserScripts()
                keep.forEach(controller.addUserScript)
            }
        }
        sessions.removeAll()
    }
}

/// The driver's state for one tab.
@MainActor
final class TabSession {
    let tabID: BrowserTabID
    let frames = FrameRegistry()
    let waits = LoadWaits()
    var mouse = MouseEventPlan()
    var mouseLocation = CGPoint.zero
    var agentReady = false
    /// The main frame's title at its last load state; WKWebView.title can
    /// lag the load event.
    var lastTitle: String?
    let messages: LoadStateMessages

    init(tabID: BrowserTabID, driver: WebKitDriver) {
        self.tabID = tabID
        messages = LoadStateMessages(tabID: tabID, driver: driver)
    }
}

/// Receives the load-state script's messages; holds the driver weakly so
/// the web view's content controller does not keep it alive.
final class LoadStateMessages: NSObject, WKScriptMessageHandler {
    let tabID: BrowserTabID
    weak var driver: WebKitDriver?

    init(tabID: BrowserTabID, driver: WebKitDriver) {
        self.tabID = tabID
        self.driver = driver
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let name = body["state"] as? String,
              let state = LoadState(name: name) else { return }
        driver?.received(state, url: body["url"] as? String ?? "", title: body["title"] as? String,
                         isMainFrame: message.frameInfo.isMainFrame, tabID: tabID)
    }
}
