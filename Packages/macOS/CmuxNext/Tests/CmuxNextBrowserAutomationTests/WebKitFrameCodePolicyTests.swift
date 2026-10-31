import AppKit
import CmuxNextBrowser
@testable import CmuxNextBrowserAutomation
import CmuxNextDesign
import Foundation
import Network
import Testing
import WebKit

@MainActor @Suite(.serialized, .timeLimit(.minutes(2))) struct WebKitFrameCodePolicyTests {
    @Test(arguments: ["page", "agent"])
    func aFilledChildFrameRefusesAgentCode(_ world: String) async throws {
        let server = try await Server.start()
        defer { server.stop() }
        var seen: [String] = []
        let policy = BrowserFrameCodePolicy(admit: { _, origins in
            seen = origins
            return origins.contains(server.childOrigin) ? "filled sign-in" : nil
        }, ran: { _, _ in })
        let page = Page(policy: policy)
        try await page.load(server.url("/"))
        let child = try await page.childFrame()
        await #expect(throws: DriverError.self) {
            try await page.evaluate("() => { document.body.dataset.ran = 'yes'; return 42; }", world: world, frame: child)
        }
        #expect(seen.contains(server.childOrigin), "admission must name the child, not just its top page")
        #expect(try await page.marker(frame: child) == .null)
    }

    @Test(arguments: ["page", "agent"])
    func navigationDuringAdmissionCannotRunSourceOnTheNewOrigin(_ world: String) async throws {
        let server = try await Server.start()
        defer { server.stop() }
        var page: Page?
        let policy = BrowserFrameCodePolicy(admit: { _, _ in
            try? await page?.load(server.url("/child", child: true))
            return nil
        }, ran: { _, _ in })
        let loaded = Page(policy: policy)
        page = loaded
        try await loaded.load(server.url("/plain"))
        await #expect(throws: DriverError.self) {
            try await loaded.evaluate("() => { document.body.dataset.ran = 'yes'; return 42; }", world: world)
        }
        #expect(try await loaded.marker() == .null)
    }

    @Test func sourceCannotEscapeWebKitsGeneratedFunctionBeforeTheOriginCheck() async throws {
        let server = try await Server.start()
        defer { server.stop() }
        var page: Page?
        let policy = BrowserFrameCodePolicy(admit: { _, _ in
            try? await page?.load(server.url("/child", child: true))
            return nil
        }, ran: { _, _ in })
        let loaded = Page(policy: policy)
        page = loaded
        try await loaded.load(server.url("/plain"))
        let source = "function(){});}); this.document.body.dataset.ran = 'yes'; (async function(__args){ return (function(){}"
        _ = try? await loaded.evaluate(source, world: "page")
        #expect(try await loaded.marker() == .null)
    }

    @Test func anAdmittedFrameRunsCodeAndMarksItsActualOrigin() async throws {
        let server = try await Server.start()
        defer { server.stop() }
        var admitted: [String] = []
        var ended: [String] = []
        let page = Page(policy: BrowserFrameCodePolicy(admit: { _, origins in admitted = origins; return nil },
                                                     ran: { _, origins in ended = origins }))
        try await page.load(server.url("/"))
        let child = try await page.childFrame()
        #expect(try await page.evaluate("() => 42", world: "page", frame: child) == .number(42))
        #expect(admitted.contains(server.childOrigin))
        #expect(ended.contains(server.childOrigin))
    }

    @Test func anAdmittedStrictCSPPageStillRunsAFunction() async throws {
        let server = try await Server.start()
        defer { server.stop() }
        let page = Page(policy: BrowserFrameCodePolicy(admit: { _, _ in nil }, ran: { _, _ in }))
        try await page.load(server.url("/strict"))
        #expect(try await page.evaluate("() => 42", world: "page") == .number(42))
    }

    @Test func aBlankTabStillRunsCodeAndReservesOpaqueOrigins() async throws {
        var admitted: [String] = []
        let page = Page(policy: BrowserFrameCodePolicy(admit: { _, origins in admitted = origins; return nil }, ran: { _, _ in }))
        try await page.load(try #require(URL(string: "about:blank")))
        #expect(try await page.evaluate("() => 42", world: "page") == .number(42))
        #expect(admitted.contains("null"))
    }

    @Test func pageWorldElementHandlesUseTheAdmittedFrame() async throws {
        let server = try await Server.start()
        defer { server.stop() }
        let page = Page(policy: BrowserFrameCodePolicy(admit: { _, _ in nil }, ran: { _, _ in }))
        try await page.load(server.url("/plain"))
        // The driver lazily installs its agent on agent-world evaluation, as the host does.
        _ = try await page.evaluate("() => true", world: "agent")
        #expect(try await page.evaluate("(el) => el.id", world: "page", handles: ["handle"]) == .string("handle"))
    }

    private final class NoFileInput: WebFileInputAnswering {
        func answerFileInput(allowsMultipleSelection: Bool, allowsDirectories: Bool, window: NSWindow?,
                             completion: @escaping @MainActor ([URL]?) -> Void) { completion(nil) }
    }

    private final class Page: NSObject, WKNavigationDelegate, AutomationTabProvider {
        private let engine: WebKitEngine
        private let policy: BrowserFrameCodePolicy
        private var loaded: CheckedContinuation<Void, any Error>?
        let tab: WebKitTab
        lazy var driver = WebKitDriver(provider: self, agentBundle: """
        globalThis[Symbol.for('cmux.browserRepl.agent')] = true;
        globalThis.__cmuxPageAgent = { resolveHandle: id => document.getElementById(id) };
        """, frameCodePolicy: policy)

        init(policy: BrowserFrameCodePolicy) {
            _ = NSApplication.shared
            let engine = WebKitEngine(fileInput: NoFileInput(), stores: .inMemory())
            self.engine = engine
            self.policy = policy
            tab = engine.makeWebKitTab()
            super.init()
            tab.webView.navigationDelegate = self
        }

        func load(_ url: URL) async throws {
            try await withCheckedThrowingContinuation { continuation in
                loaded = continuation
                tab.webView.load(URLRequest(url: url))
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { loaded?.resume(); loaded = nil }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
            loaded?.resume(throwing: error); loaded = nil
        }

        func childFrame() async throws -> String {
            let frames = try await driver.call(method: "frames.list", params: .object(["targetId": .string(tab.id.rawValue)]))
            guard case .array(let list) = frames,
                  let child = list.compactMap({ value -> [String: DriverJSON]? in
                      guard case .object(let fields) = value else { return nil }
                      return fields
                  }).first(where: { $0["parentFrameId"] != .null }),
                  case .string(let id)? = child["frameId"] else { throw DriverError(.notFound, "child frame") }
            return id
        }

        @discardableResult func evaluate(_ source: String, world: String, frame: String = "main", handles: [String] = []) async throws -> DriverJSON {
            try await driver.call(method: "frame.evaluate", params: .object(["targetId": .string(tab.id.rawValue), "source": .string(source),
                                                                            "world": .string(world), "frameId": .string(frame),
                                                                            "args": .array([]), "handles": .array(handles.map(DriverJSON.string))]))
        }

        func marker(frame: String = "main") async throws -> DriverJSON {
            let params = try DriverParams(method: "test", json: .object(["targetId": .string(tab.id.rawValue), "frameId": .string(frame)]))
            let info = try await driver.frameInfo(params, tab: tab, session: driver.session(for: tab))
            return try await driver.run("return this.document.body.dataset.ran ?? null", [:], info, AgentWorld.hostWorld, tab)
        }

        func automationTabs(all: Bool) -> [AutomationTab] { [AutomationTab(tab: tab, windowID: "test", isActive: true)] }
        func openAutomationTab(url: URL?) async throws -> WebKitTab { tab }
        func closeAutomationTab(_ id: BrowserTabID) {}
        func endSessionTab(_ id: String) async -> Bool { false }
        func activateAutomationTab(_ id: BrowserTabID) {}
    }

    // concurrency-allow: Network.framework owns listener/connection synchronization; all handler
    // state is immutable and no mutable Swift state crosses its serial callback queue.
    private nonisolated final class Server: @unchecked Sendable {
        let listener: NWListener
        let port: UInt16
        var childOrigin: String { "http://localhost:\(port)" }
        private init(listener: NWListener, port: UInt16) { self.listener = listener; self.port = port }

        static func start() async throws -> Server {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
            let listener = try NWListener(using: parameters)
            let queue = DispatchQueue(label: "pr25858-frame-policy-test")
            listener.newConnectionHandler = { connection in
                connection.start(queue: queue)
                connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, _, _ in
                    let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                    let path = request.split(separator: " ").dropFirst().first ?? "/"
                    let childOrigin = "http://localhost:\(listener.port?.rawValue ?? 0)"
                    let body = path == "/" ? "<iframe src='\(childOrigin)/child'></iframe>" : "<p id='handle'>frame</p>"
                    let html = "<!doctype html><html><body>\(body)</body></html>"
                    let csp = path == "/strict" ? "Content-Security-Policy: script-src 'none'\r\n" : ""
                    let head = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n\(csp)Content-Length: \(html.utf8.count)\r\nConnection: close\r\n\r\n"
                    connection.send(content: Data((head + html).utf8), completion: .contentProcessed { _ in connection.cancel() })
                }
            }
            let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
                listener.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        listener.stateUpdateHandler = nil
                        continuation.resume(returning: listener.port?.rawValue ?? 0)
                    case .failed(let error):
                        listener.stateUpdateHandler = nil
                        continuation.resume(throwing: error)
                    default: break
                    }
                }
                listener.start(queue: queue)
            }
            return Server(listener: listener, port: port)
        }

        func url(_ path: String, child: Bool = false) throws -> URL {
            try #require(URL(string: "http://\(child ? "localhost" : "127.0.0.1"):\(port)\(path)"))
        }
        func stop() { listener.cancel() }
    }
}
