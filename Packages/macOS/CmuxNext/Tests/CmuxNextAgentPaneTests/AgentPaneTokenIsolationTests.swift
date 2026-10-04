import AppKit
import Foundation
import Testing
import WebKit
@testable import CmuxNextAgentPane

/// A host that names the stand-in daemon, with a dashboard token and a LocalApp token file.
private actor StandInHost: AgentPaneHostProviding {
    let url: URL
    let home: URL
    init(url: URL, home: URL) { self.url = url; self.home = home }
    func handshake(sessionId: String?) async throws -> AgentPaneHandshake {
        .acpmux(AcpmuxConnection(endpoint: AcpmuxWebEndpoint(url: url, token: AgentPaneTokenIsolationTests.dashboard), home: home),
                sessionId: sessionId)
    }
}

/// The page world never sees either token (localapp-isolation-spike.md, design B). A script in
/// the page world that runs before the pane (XSS, a bad dependency, the user's registry.js)
/// patches every place a frame or a token could pass, and records what it saw; the real bundled
/// pane then connects through the host. The daemon must receive both tokens; the spy must see
/// frames and neither token.
@MainActor
@Suite(.serialized) struct AgentPaneTokenIsolationTests {
    nonisolated static let dashboard = "dash" + String(repeating: "d4", count: 20)
    nonisolated static let localApp = String(repeating: "e5", count: 32)

    /// Records into `window.__spySeen` everything that crosses the page world.
    nonisolated static let spy = #"""
    (() => {
      const seen = (window.__spySeen = []);
      const stringify = JSON.stringify;
      let inside = false;
      const note = (where, value) => {
        if (inside) return;
        inside = true;
        try { seen.push(where + ":" + (typeof value === "string" ? value : stringify(value))); } catch (_) { seen.push(where + ":?"); }
        inside = false;
      };
      const wrap = (owner, name, where) => {
        const original = owner && owner[name];
        if (typeof original !== "function") return;
        owner[name] = function (...args) {
          note(where, args);
          const result = original.apply(this, args);
          if (result && typeof result.then === "function") result.then((value) => note(where + ".reply", value), () => {});
          return result;
        };
      };
      wrap(WebSocket.prototype, "send", "ws.send");
      const NativeWebSocket = window.WebSocket;
      window.WebSocket = function (...args) { note("ws.new", args); return new NativeWebSocket(...args); };
      window.WebSocket.prototype = NativeWebSocket.prototype;
      Object.assign(window.WebSocket, { CONNECTING: 0, OPEN: 1, CLOSING: 2, CLOSED: 3 });
      wrap(JSON, "stringify", "json.stringify");
      wrap(JSON, "parse", "json.parse");
      wrap(window, "fetch", "fetch");
      wrap(window, "postMessage", "window.postMessage");
      wrap(MessagePort.prototype, "postMessage", "port.postMessage");
      try { wrap(window.webkit.messageHandlers.agentSession, "postMessage", "bridge"); } catch (_) {}
      const data = Object.getOwnPropertyDescriptor(MessageEvent.prototype, "data");
      if (data && data.get) Object.defineProperty(MessageEvent.prototype, "data", {
        configurable: true, get() { const value = data.get.call(this); note("event.data", value); return value; },
      });
    })();
    """#

    @Test func thePageWorldNeverSeesEitherToken() async throws {
        let server = AcpmuxStandInServer()
        try await server.start()
        defer { server.stop() }
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("acpmux-home-\(UUID().uuidString)")
        let tokenFile = AcpmuxLocalAppToken.path(home: home)
        try FileManager.default.createDirectory(at: tokenFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.localApp.write(to: tokenFile, atomically: true, encoding: .utf8)

        let model = AgentPaneModel(host: StandInHost(url: server.url, home: home))
        let view = try #require(AgentPaneView(model: model))
        defer { view.close() }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView?.addSubview(view)
        view.frame = window.contentView?.bounds ?? .zero
        // The spy runs first in the page world of every load; reload so this load has it.
        view.webView.configuration.userContentController.addUserScript(
            WKUserScript(source: Self.spy, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page))
        view.webView.reload()

        let connected = await server.wait(seconds: 30) { peers in peers.last?.frames.first?.contains(Self.localApp) == true }
        if !connected {
            let text = (try? await view.webView.evaluateJavaScript("document.body ? document.body.innerText.slice(0, 400) : 'no body'") as? String) ?? "?"
            Issue.record("no LocalApp initialize: handshake=\(model.hasHandshake) peers=\(server.peers.count) frames=\(server.peers.map(\.frames.count)) page=\(text)")
            return
        }
        let peer = try #require(server.peers.last)
        #expect(peer.authorization == "Bearer \(Self.dashboard)")
        #expect(peer.origin == AcpmuxConnection.paneOrigin)
        // Let the initialize reply and the next requests cross the page.
        #expect(await server.wait(seconds: 10) { ($0.last?.frames.count ?? 0) >= 2 })

        let seen = try #require(try await view.webView.evaluateJavaScript("JSON.stringify(window.__spySeen || [])") as? String)
        let dom = try #require(try await view.webView.evaluateJavaScript("document.documentElement.outerHTML") as? String)
        #expect(seen.contains("initialize"), "the spy saw the page's frames")
        #expect(!seen.contains(Self.localApp))
        #expect(!seen.contains(Self.dashboard))
        #expect(!dom.contains(Self.localApp) && !dom.contains(Self.dashboard))
        #expect(!seen.contains("ws.new"), "the page opened no WebSocket of its own")
    }
}
