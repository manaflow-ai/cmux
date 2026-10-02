import CmuxNextBrowser
import Foundation
import WebKit

extension WebKitDriver {
    static let needsAgent = "__cmuxNeedsAgent__"
    private static let agentKey = #"globalThis[Symbol.for("cmux.browserRepl.agent")]"#

    func framesList(_ params: DriverParams) async throws(DriverError) -> DriverJSON {
        let (tab, session) = try target(params)
        let frames = await session.frames.refresh(tab.webView)
        guard !frames.isEmpty else {
            // Without the frame-tree SPI only the main frame is known.
            return .array([.object(["frameId": .string("main"), "parentFrameId": .null,
                                    "url": .string(tab.webView.url?.absoluteString ?? ""), "name": .string(""),
                                    "crossOrigin": .bool(false)])])
        }
        let mainOrigin = frames.first.map(Self.origin) ?? ""
        return .array(frames.map { frame in
            .object([
                "frameId": .string(frame.frameID),
                "parentFrameId": frame.parentFrameID.map(DriverJSON.string) ?? .null,
                "url": .string(frame.url),
                "name": .string(""),
                "crossOrigin": .bool(Self.origin(frame) != mainOrigin),
            ])
        })
    }

    /// `(<source>)(...handles, ...args)` in one frame and world, awaiting a
    /// returned promise. Agent-world calls install the page agent on a miss.
    func frameEvaluate(_ params: DriverParams) async throws(DriverError) -> DriverJSON {
        let (tab, session) = try target(params)
        let source = try params.string("source")
        let world = try params.optionalString("world") ?? "page"
        let args = try params.array("args").map(\.foundationValue)
        let handles = try params.strings("handles")
        let frame = try await frameInfo(params, tab: tab, session: session)
        if world == "agent" {
            let body = "if (!\(Self.agentKey)) return \"\(Self.needsAgent)\"; return await (\(source))(...__handlesThenArgs(__handles, __args));"
            let call = Self.withHandles(body)
            let first = try await run(call, ["__handles": handles, "__args": args], frame, AgentWorld.world, tab)
            guard first == .string(Self.needsAgent) else { return first }
            try await installAgent(frame: frame, tab: tab)
            return try await run(call, ["__handles": handles, "__args": args], frame, AgentWorld.world, tab)
        }
        if world == "host" {
            guard handles.isEmpty else { throw DriverError(.invalid, "frame.evaluate: the host world takes no element handles") }
            return try await run("return await (\(source))(...__args);", ["__args": args], frame, AgentWorld.hostWorld, tab)
        }
        guard !handles.isEmpty else {
            return try await run("return await (\(source))(...__args);", ["__args": args], frame, .page, tab)
        }
        return try await evaluateInPage(source: source, handles: handles, args: args, frame: frame, tab: tab)
    }

    /// Agent handles live in the agent world; a page-world function gets the
    /// same elements through the DOM: the page world listens for a one-off
    /// event type, the agent world dispatches it on each element.
    private func evaluateInPage(source: String, handles: [String], args: [Any], frame: WKFrameInfo?, tab: WebKitTab) async throws(DriverError) -> DriverJSON {
        let token = "cmux-handoff-" + UUID().uuidString.lowercased()
        _ = try await run("""
        const list = []; const on = (e) => list.push(e.composedPath()[0]);
        addEventListener(token, on, { capture: true });
        (globalThis.__cmuxHandoff ||= new Map()).set(token, { list, on });
        return true;
        """, ["token": token], frame, .page, tab)
        let dispatched = try await run("""
        for (const id of ids) {
          const el = globalThis.__cmuxPageAgent && globalThis.__cmuxPageAgent.resolveHandle(id);
          if (!el || !el.isConnected) return false;
          // The page world cannot see into a closed shadow root: the event
          // would reach it retargeted to the host element.
          for (let root = el.getRootNode(); root instanceof ShadowRoot; root = root.host.getRootNode()) {
            if (root.mode === "closed") return "closed-shadow";
          }
          el.dispatchEvent(new Event(token, { bubbles: true, composed: true }));
        }
        return true;
        """, ["token": token, "ids": handles], frame, AgentWorld.world, tab)
        if dispatched == .string("closed-shadow") {
            throw DriverError(.unsupported, "frame.evaluate: an element inside a closed shadow root cannot be passed to page code")
        }
        let result = try await run("""
        const entry = globalThis.__cmuxHandoff.get(token);
        globalThis.__cmuxHandoff.delete(token);
        removeEventListener(token, entry.on, { capture: true });
        if (!stale && entry.list.length === count) return await (\(source))(...entry.list, ...__args);
        return { __cmuxStale: true };
        """, ["token": token, "__args": args, "stale": dispatched != .bool(true), "count": handles.count], frame, .page, tab)
        if case .object(let object) = result, object["__cmuxStale"] == .bool(true) {
            throw DriverError(.stale, "Element is not attached to the DOM")
        }
        return result
    }

    private static func withHandles(_ body: String) -> String {
        """
        const __handlesThenArgs = (ids, args) => {
          const agent = globalThis.__cmuxPageAgent;
          const els = ids.map((id) => { const el = agent && agent.resolveHandle(id); if (!el) throw Object.assign(new Error("Element is not attached to the DOM"), { name: "StaleElement" }); return el; });
          return [...els, ...args];
        };
        \(body)
        """
    }

    private func installAgent(frame: WKFrameInfo?, tab: WebKitTab) async throws(DriverError) {
        guard let agentBundle else { throw DriverError(.unsupported, "frame.evaluate: the host sent no page agent") }
        let ok = try await run(AgentWorld.ensureAgentSource(bundle: agentBundle), [:], frame, AgentWorld.world, tab)
        guard ok == .bool(true) else { throw DriverError(.unsupported, "frame.evaluate: the page agent did not install") }
    }

    private func frameInfo(_ params: DriverParams, tab: WebKitTab, session: TabSession) async throws(DriverError) -> WKFrameInfo? {
        guard let id = try params.optionalString("frameId"), id != "main", id != session.frames.mainFrameID else { return nil }
        guard let record = await session.frames.frame(id, in: tab.webView) else {
            throw DriverError(.notFound, "\(params.method): frame \(id) was detached")
        }
        return record.info
    }

    func run(_ body: String, _ arguments: [String: Any], _ frame: WKFrameInfo?, _ world: WKContentWorld, _ tab: WebKitTab) async throws(DriverError) -> DriverJSON {
        do {
            let value = try await tab.webView.callAsyncJavaScript(body, arguments: arguments, in: frame, contentWorld: world)
            return DriverJSON(foundation: value)
        } catch let error as WKError where error.code == .javaScriptResultTypeIsUnsupported {
            return .null
        } catch let error as WKError where error.code == .javaScriptExceptionOccurred {
            let message = error.userInfo["WKJavaScriptExceptionMessage"] as? String ?? error.localizedDescription
            if message.contains("StaleElement") || message.contains("not attached to the DOM") {
                throw DriverError(.stale, "Element is not attached to the DOM")
            }
            throw DriverError(.evaluation, message, errorName: message.split(separator: ":").first.map(String.init))
        } catch let error as WKError where error.code == .javaScriptInvalidFrameTarget {
            throw DriverError(.notFound, "the frame was detached")
        } catch let error as WKError where error.code == .webContentProcessTerminated || error.code == .webViewInvalidated {
            throw DriverError(.closed, "Target page, context or browser has been closed")
        } catch {
            throw DriverError(.evaluation, error.localizedDescription)
        }
    }

    private static func origin(_ frame: FrameRecord) -> String {
        let origin = frame.info.securityOrigin
        return "\(origin.protocol)://\(origin.host):\(origin.port)"
    }
}
