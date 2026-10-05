import Testing
import WebKit

@testable import CmuxBrowser

/// Two sessions that drive one tab each run their page agent, and any
/// `source` they send with `world: "agent"`, in a content world of their
/// own. What one session's code does in its world (patch built-ins, the DOM
/// prototypes, `window.frames`, the agent object) never reaches the other's
/// refs, hit test, press check or frame positions. These tests load real
/// pages in WebKit with the repository's page agent.
@MainActor
@Suite("Session worlds", .serialized)
struct BrowserReplSessionWorldTests {
    private static let agent = #"globalThis[Symbol.for("cmux.browserRepl.agent")]"#
    private static let presence = "cmuxReplAgent"

    private static let page = """
        <body style="margin:0">
        <button id=real style="position:absolute;left:100px;top:100px;width:120px;height:40px">Real</button>
        <button id=decoy style="position:absolute;left:100px;top:200px;width:120px;height:40px">Decoy</button>
        <iframe id=f style="position:absolute;left:260px;top:0;width:100px;height:80px;border:0" srcdoc="<p>child</p>"></iframe>
        </body>
        """

    private static func call(_ body: String, in world: WKContentWorld, of webView: WKWebView, arguments: [String: Any] = [:]) async throws -> Any? {
        try await webView.callAsyncJavaScript(body, arguments: arguments, in: nil, contentWorld: world)
    }

    /// What session B's code tries in its own world against session A.
    private static let tamper = """
        const K = Symbol.for("cmux.browserRepl.agent");
        const a = globalThis[K];
        const decoy = document.getElementById("decoy");
        const tries = {
          methods: () => { a.pressCheck = () => null; a.elementAt = () => ({ name: "forged" }); if (a.pressCheck() !== null) throw 0; },
          replace: () => { delete globalThis[K]; globalThis[K] = { element: () => decoy }; if (globalThis[K].element() !== decoy) throw 0; },
          deref: () => { WeakRef.prototype.deref = function () { return decoy; }; },
          mapGet: () => { const get = Map.prototype.get; Map.prototype.get = function (k) { const v = get.call(this, k); return v && typeof v.deref === "function" ? new WeakRef(decoy) : v; }; },
          rect: () => { const r = decoy.getBoundingClientRect(); Element.prototype.getBoundingClientRect = function () { return r; }; },
          hit: () => { Document.prototype.elementFromPoint = function () { return decoy; }; Document.prototype.elementsFromPoint = function () { return [decoy]; }; },
          filter: () => { Array.prototype.filter = function () { return []; }; },
          frames: () => { Object.defineProperty(window, "frames", { get: () => ({ length: 0 }), configurable: true }); },
          contentWindow: () => { Object.defineProperty(HTMLIFrameElement.prototype, "contentWindow", { get: () => null, configurable: true }); },
        };
        const out = {};
        for (const [k, f] of Object.entries(tries)) { try { f(); out[k] = "applied"; } catch (e) { out[k] = "refused"; } }
        return out;
        """

    /// What session A reads back: its handle's element, the hit test at the
    /// real button's center, the press check there, the iframe's position
    /// in `window.frames`, the document token on its ref, and whether its
    /// built-ins are still the engine's.
    private static let check = """
        const ag = \(agent);
        const real = document.getElementById("real");
        const iframe = document.getElementById("f");
        let index = -1;
        for (let i = 0; i < window.frames.length; i++) if (window.frames[i] === iframe.contentWindow) index = i;
        const native = (f) => /\\[native code\\]/.test(Function.prototype.toString.call(f));
        const at = ag.elementAt(160, 120, 0);
        return {
          element: ag.element(handle) === real,
          at: at && at.name,
          press: ag.pressCheck(handle, { x: 160, y: 120 }, null),
          frameIndex: index,
          doc: ag.refForHandle(handle, 0).doc,
          natives: [WeakRef.prototype.deref, Map.prototype.get, Element.prototype.getBoundingClientRect,
            Document.prototype.elementFromPoint, Array.prototype.filter].every(native),
        };
        """

    @Test func anotherSessionsCodeCannotChangeASessionsRefsHitTestPressOrFrames() async throws {
        let source = try #require(try browserReplRepositoryBundle().agentInstallSource)
        let a = BrowserReplSessionWorld()
        let b = BrowserReplSessionWorld()
        let installers = [BrowserReplAgentUserScript(), BrowserReplAgentUserScript()]
        let loaded = try await FramePage.load(html: Self.page, loaded: { $0.count >= 2 }) { configuration in
            for (installer, session) in zip(installers, [a, b]) {
                installer.install(source: source, presenceHandlerName: Self.presence, world: session.agent, in: configuration.userContentController)
            }
        }
        let webView = loaded.webView
        // Each session's document-start script put an agent in its world.
        for session in [a, b] {
            let present = try await Self.call("return \(Self.agent) !== undefined;", in: session.agent, of: webView) as? Bool
            #expect(present == true, "no page agent in \(session.name)")
            // As the driver's first evaluation does in a frame without one.
            _ = try? await webView.evaluateJavaScript(source, in: nil, contentWorld: session.agent)
        }
        let handle = try #require(try await Self.call(
            "return \(Self.agent).handleFor(document.getElementById('real'));", in: a.agent, of: webView
        ) as? String)
        let before = try #require(try await Self.call(Self.check, in: a.agent, of: webView, arguments: ["handle": handle]) as? [String: Any])
        #expect(before["element"] as? Bool == true)
        #expect(before["at"] as? String == "Real")

        let tried = try #require(try await Self.call(Self.tamper, in: b.agent, of: webView) as? [String: String])
        #expect(tried["deref"] == "applied", "B's code runs in B's world: \(tried)")

        let after = try #require(try await Self.call(Self.check, in: a.agent, of: webView, arguments: ["handle": handle]) as? [String: Any])
        #expect(after["element"] as? Bool == true, "A's handle resolves to another element: \(after)")
        #expect(after["at"] as? String == "Real", "A's hit test was redirected: \(after)")
        #expect(after["press"] is NSNull, "A's press check was changed: \(after)")
        #expect(after["frameIndex"] as? Int == 0, "A's frame position was changed: \(after)")
        #expect(after["doc"] as? String == before["doc"] as? String, "A's document token was changed: \(after)")
        #expect(after["natives"] as? Bool == true, "A's built-ins were replaced: \(after)")
    }

    /// `frame.evaluate` runs a session's `source` in its agent world or the
    /// page's, whatever `world` names, so the driver's guard worlds keep what
    /// they hold out of every session's reach.
    @Test func sessionSourceNeverRunsInAGuardWorld() async throws {
        let session = BrowserReplSessionWorld()
        let guardWorld = WKContentWorld.world(name: "cmux-session-world-tests-guard")
        let loaded = try await FramePage.load(html: "<p>page</p>", loaded: { !$0.isEmpty })
        _ = try await Self.call("globalThis.guardMark = 1; return true;", in: guardWorld, of: loaded.webView)
        for name in ["agent", "page", "cmux-driver", "cmux-capture-mask", "cmux-repl-copy-probe", "cmux-session-world-tests-guard", session.name, ""] as [String?] + [nil] {
            let world = session.evaluationWorld(name)
            #expect(world === session.agent || world === WKContentWorld.page, "\(name ?? "nil") names another world")
            let seen = try await Self.call("return typeof globalThis.guardMark;", in: world, of: loaded.webView) as? String
            #expect(seen == "undefined", "\(name ?? "nil") reached the guard world")
        }
    }

    /// A session that starts after another ended never gets its world: a
    /// world's name is used once, so nothing the ended session left in a
    /// document reaches the next.
    @Test func aLaterSessionGetsAFreshWorld() async throws {
        let loaded = try await FramePage.load(html: "<p>page</p>", loaded: { !$0.isEmpty })
        var first: BrowserReplSessionWorld? = BrowserReplSessionWorld()
        let firstName = try #require(first?.name)
        _ = try await Self.call("globalThis.leftBehind = 1; return true;", in: try #require(first?.agent), of: loaded.webView)
        first = nil
        let second = BrowserReplSessionWorld()
        #expect(second.name != firstName)
        #expect(second.name.hasPrefix("cmux-agent-"))
        let seen = try await Self.call("return typeof globalThis.leftBehind;", in: second.agent, of: loaded.webView) as? String
        #expect(seen == "undefined")
    }

    /// Each session that drives a tab has its agent script in the tab's
    /// controller; one leaving removes only its own.
    @Test func eachSessionHasItsOwnAgentScriptInATab() {
        let controller = WKUserContentController()
        let a = BrowserReplAgentUserScript()
        let b = BrowserReplAgentUserScript()
        a.install(source: "1;", presenceHandlerName: Self.presence, world: BrowserReplSessionWorld().agent, in: controller)
        b.install(source: "2;", presenceHandlerName: Self.presence, world: BrowserReplSessionWorld().agent, in: controller)
        #expect(controller.userScripts.count == 2)
        a.release()
        #expect(controller.userScripts.count == 1)
        #expect(controller.userScripts.first?.source.contains("2;") == true)
        b.release()
        #expect(controller.userScripts.isEmpty)
    }

    @Test func aTabRefusesTheSessionPastItsLimit() throws {
        let limit = BrowserReplTabSessionLimit(limit: 2)
        try limit.admit("a", attached: [String]())
        try limit.admit("b", attached: ["a"])
        // A session already attached is not counted again.
        try limit.admit("a", attached: ["a", "b"])
        do {
            try limit.admit("c", attached: ["a", "b"])
            Issue.record("a third session was admitted to a tab limited to 2")
        } catch let error as BrowserReplDriverError {
            #expect(error.code == "limit")
            #expect(error.message.contains("at most 2"), "\(error.message)")
        }
        #expect(BrowserReplTabSessionLimit.standard.limit < 64)
    }
}
