@testable import CmuxNextApps
import Foundation
import Testing
import WebKit

/// A custom pane in a real web view (plans/cmux-next/custom-panes-DESIGN.md
/// sections 2 and 3): the page loads from its package under its own origin,
/// `cmux.call` reaches the supervisor and its refusals reject with their code,
/// the console reaches the app log, the host policy blocks the network and
/// inline script, the page cannot leave its origin, and a file change reloads it.
private let pageSource = """
    <!doctype html><title>Board</title><script>window.inline = 1</script><script src="app.js"></script>
    """
private let scriptSource = """
    window.version = "one";
    window.boom = () => setTimeout(() => { throw new Error("boom") }, 0);
    console.info("ready", window.version);
    """

@MainActor
struct AppWebPaneTests {
    @Test(.timeLimit(.minutes(1))) func aPaneCallsTheSupervisorUnderItsOwnApp() async throws {
        let app = try TempApp()
        let calls = FakeCalls()
        let view = try app.view(calls: calls)
        await calls.waitForLog("ready one")

        calls.answer = .success(.object(["value": .array([.object(["id": .string("ws_1")])])]))
        let listed = try await view.webView.callAsyncJavaScript(
            "return (await cmux.call('workspace.list', { limit: 2 })).value[0].id", arguments: [:], in: nil, contentWorld: .page
        ) as? String
        #expect(listed == "ws_1")
        #expect(calls.calls.first?.app == "local/board")
        #expect(calls.calls.first?.op == "workspace.list")
        #expect(calls.calls.first?.params == .object(["limit": .number(2)]))

        calls.answer = .failure(.refused(AppsTransportError(code: "scope.missing", message: "not granted")))
        let refused = try await view.webView.callAsyncJavaScript(
            "try { await cmux.call('workspace.rename', { name: 'x' }); return 'ran' } catch (e) { return e.code + ': ' + e.message }",
            arguments: [:], in: nil, contentWorld: .page
        ) as? String
        #expect(refused == "scope.missing: not granted")

        let badParams = try await view.webView.callAsyncJavaScript(
            "try { await cmux.call('workspace.list', [1]); return 'ran' } catch (e) { return e.code }",
            arguments: [:], in: nil, contentWorld: .page
        ) as? String
        #expect(badParams == "bridge.invalid")
        #expect(calls.calls.count == 2, "a malformed call never reaches the supervisor")
    }

    @Test(.timeLimit(.minutes(1))) func thePagesConsoleAndErrorsReachTheAppLog() async throws {
        let app = try TempApp()
        let calls = FakeCalls()
        let view = try app.view(calls: calls)
        await calls.waitForLog("ready one")
        _ = try await view.webView.callAsyncJavaScript("""
            console.warn("careful", { n: 1 });
            window.boom();
            await new Promise((r) => setTimeout(r, 0));
            console.info("done");
            """, arguments: [:], in: nil, contentWorld: .page)
        await calls.waitForLog("done")
        #expect(calls.logs.contains { $0.level == "warn" && $0.message == #"careful {"n":1}"# }, "\(calls.logs)")
        #expect(calls.logs.contains { $0.level == "error" && $0.message.contains("boom") }, "\(calls.logs)")
        #expect(calls.logs.allSatisfy { $0.app == "local/board" })
    }

    @Test(.timeLimit(.minutes(1))) func theHostPolicyKeepsThePageInItsPackage() async throws {
        let app = try TempApp()
        let calls = FakeCalls()
        let view = try app.view(calls: calls)
        await calls.waitForLog("ready one")
        let result = try await view.webView.callAsyncJavaScript("""
            const reach = async (url) => { try { await fetch(url); return "reached" } catch { return "blocked" } };
            return [
              typeof window.inline,
              await reach("https://example.com/"),
              await reach("cmux-app://other.app/index.html"),
              await reach("app.js"),
              await reach("../cmux-app.json"),
            ].join(",");
            """, arguments: [:], in: nil, contentWorld: .page) as? String
        // Inline script and every other origin are refused; its own file loads. `../` resolves
        // to the web root here (URL parsing), where there is no manifest; escaping paths are
        // refused by ``AppWebPane/file(for:)`` (thePaneReadsOnlyItsWebRoot).
        #expect(result == "undefined,blocked,blocked,reached,blocked", "\(result ?? "nil")")

        // No peer connections, and the page cannot bring them back.
        let rtc = try await view.webView.callAsyncJavaScript("""
            try { window.RTCPeerConnection = function () {}; } catch {}
            return [typeof RTCPeerConnection, typeof webkitRTCPeerConnection, typeof RTCDataChannel].join(",");
            """, arguments: [:], in: nil, contentWorld: .page) as? String
        #expect(rtc == "undefined,undefined,undefined", "\(rtc ?? "nil")")

        let (refused, refusal) = AsyncStream.makeStream(of: Void.self)
        view.onRefusedNavigation = { refusal.yield() }
        _ = try? await view.webView.evaluateJavaScript("location.href = 'https://example.com/'")
        _ = await refused.first { _ in true }
        #expect(view.webView.url == view.pane.entryURL, "the page stays on its own origin")
    }

    @Test(.timeLimit(.minutes(1))) func aFileChangeReloadsThePageFromDisk() async throws {
        let app = try TempApp()
        let calls = FakeCalls()
        let view = try app.view(calls: calls)
        await calls.waitForLog("ready one")
        try scriptSource.replacingOccurrences(of: "\"one\"", with: "\"two\"").write(to: app.web.appendingPathComponent("app.js"), atomically: true, encoding: .utf8)
        view.filesChanged()
        await calls.waitForLog("ready two")
        #expect(view.hotReloads == 1)
    }

    @Test func thePaneReadsOnlyItsWebRoot() throws {
        let app = try TempApp()
        let pane = try #require(AppWebPane(manifest: app.manifest, bundle: app.root))
        #expect(pane.host == "local.board")
        #expect(pane.entryURL.absoluteString == "cmux-app://local.board/index.html")
        let file = { (text: String) in pane.file(for: URL(string: text)!)?.lastPathComponent }
        #expect(file("cmux-app://local.board/app.js") == "app.js")
        #expect(file("cmux-app://local.board/") == "index.html")
        #expect(file("cmux-app://local.board/../cmux-app.json") == nil)
        #expect(file("cmux-app://local.board/%2E%2E/cmux-app.json") == nil)
        #expect(file("cmux-app://local.board/.secret") == nil)
        #expect(file("cmux-app://other.app/app.js") == nil)
        #expect(file("https://local.board/app.js") == nil)
        try FileManager.default.createSymbolicLink(at: app.web.appendingPathComponent("out"), withDestinationURL: app.root)
        #expect(file("cmux-app://local.board/out/cmux-app.json") == nil, "a symlink cannot lead out of the root")

        let headers = pane.headers(for: app.web.appendingPathComponent("index.html"), length: 3)
        #expect(headers["Content-Security-Policy"] == AppWebPane.hostCSP + ", img-src 'none'")
        #expect(headers["Content-Type"] == "text/html; charset=utf-8")
        #expect(headers["Cache-Control"] == "no-store")

        var leaky = app.manifestJSON
        leaky["runtime"] = .object(["web": .object([
            "root": .string("web/"), "csp": .string("img-src 'none'; report-uri https://evil.example/r"),
        ])])
        let leakyManifest = try #require(AppManifest(json: .object(leaky)))
        #expect(AppWebPane(manifest: leakyManifest, bundle: app.root) == nil,
                "a policy that names a URL to send to is refused")
        #expect(AppWebPane.cspAllowed("img-src 'none', sandbox allow-scripts"))
        #expect(!AppWebPane.cspAllowed("default-src 'self'; Report-To leak"))

        // A web root that is itself a symlink out of the package serves nothing.
        let outside = try TempApp()
        let linked = FileManager.default.temporaryDirectory.appendingPathComponent("web-pane-link-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: linked, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: linked.appendingPathComponent("web"), withDestinationURL: outside.web)
        #expect(AppWebPane(manifest: app.manifest, bundle: linked) == nil, "the root leaves the package")

        var dashed = app.manifestJSON
        dashed["id"] = .string("local/workspace-board")
        let dashedManifest = try #require(AppManifest(json: .object(dashed)))
        let named = try #require(AppWebPane(manifest: dashedManifest, bundle: app.root))
        #expect(named.entryURL.absoluteString == "cmux-app://local.workspace_board/index.html", "the daemon's app_namespace")
        #expect(named.isOwn(named.entryURL))

        var escaping = app.manifestJSON
        escaping["implements"] = .object(["cmux.pane/1": .object(["web": .string("cmux-app.json")])])
        let escapingManifest = try #require(AppManifest(json: .object(escaping)))
        #expect(AppWebPane(manifest: escapingManifest, bundle: app.root) == nil,
                "a page outside the web root is no pane")
    }
}

/// `local/board` with a web pane at `web/index.html`, in a temp folder.
@MainActor
private struct TempApp {
    let root: URL
    let web: URL
    let manifestJSON: [String: AppJSON]
    var manifest: AppManifest { AppManifest(json: .object(manifestJSON))! }

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("web-pane-\(UUID().uuidString)")
        web = root.appendingPathComponent("web")
        try FileManager.default.createDirectory(at: web, withIntermediateDirectories: true)
        manifestJSON = [
            "manifestVersion": .number(2), "id": .string("local/board"), "name": .string("Board"), "version": .string("0.1.0"),
            "runtime": .object(["web": .object(["root": .string("web/"), "csp": .string("img-src 'none'")])]),
            "implements": .object(["cmux.pane/1": .object(["web": .string("web/index.html"), "title": .string("Board")])]),
        ]
        try "{}".write(to: root.appendingPathComponent("cmux-app.json"), atomically: true, encoding: .utf8)
        try ".".write(to: web.appendingPathComponent(".secret"), atomically: true, encoding: .utf8)
        try pageSource.write(to: web.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
        try scriptSource.write(to: web.appendingPathComponent("app.js"), atomically: true, encoding: .utf8)
    }

    func view(calls: FakeCalls) throws -> AppWebPaneView {
        let pane = try #require(AppWebPane(manifest: manifest, bundle: root))
        let view = AppWebPaneView(pane: pane, calls: calls)
        view.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        return view
    }
}

/// Records calls and console lines; answers every call with `answer`.
@MainActor
private final class FakeCalls: AppWebPaneCalls {
    var answer: Result<AppJSON, AppsClientError> = .success(.object([:]))
    private(set) var calls: [(app: String, op: String, params: AppJSON)] = []
    private(set) var logs: [(app: String, level: String, message: String)] = []
    private var waiting: (text: String, continuation: CheckedContinuation<Void, Never>)?

    func webCall(app: String, op: String, params: AppJSON) async throws(AppsClientError) -> AppJSON {
        calls.append((app, op, params))
        return try answer.get()
    }

    func webLog(app: String, level: String, message: String) {
        logs.append((app, level, message))
        if let waiting, message == waiting.text {
            self.waiting = nil
            waiting.continuation.resume()
        }
    }

    /// Returns once a console line equal to `text` has arrived.
    func waitForLog(_ text: String) async {
        if logs.contains(where: { $0.message == text }) { return }
        await withCheckedContinuation { waiting = (text, $0) }
    }
}
