import Foundation
import WebKit

/// The isolated content world the page agent lives in, `cmux-agent`: shares
/// the DOM with the page but not its globals, so page script cannot tamper
/// with the agent. Where WebKit offers it (SPI `_WKContentWorldConfiguration`),
/// the world may enter closed shadow roots, which Playwright's selectors need.
@MainActor
enum AgentWorld {
    static let name = "cmux-agent"
    static let loadStateHandler = "cmuxAgentLoadState"

    static let world: WKContentWorld = makeWorld()

    /// The browser host's own world (driver world "host"): no page agent,
    /// its own prototypes, never addressed by agent code (the host refuses
    /// such calls). Focus checks and capture masking run here.
    static let hostWorld: WKContentWorld = .world(name: "cmux-host")

    /// Whether the closed-shadow-root SPI was available when the world was made.
    private(set) static var reachesClosedShadowRoots = false

    private static func makeWorld() -> WKContentWorld {
        guard let configClass = NSClassFromString("_WKContentWorldConfiguration") as? NSObject.Type else {
            return .world(name: name)
        }
        let config = configClass.init()
        let closedShadow = NSSelectorFromString("setAllowAccessToClosedShadowRoots:")
        let setName = NSSelectorFromString("setName:")
        let make = NSSelectorFromString("_worldWithConfiguration:")
        guard config.responds(to: closedShadow), config.responds(to: setName),
              (WKContentWorld.self as AnyObject).responds(to: make) else {
            return .world(name: name)
        }
        config.setValue(true, forKey: "allowAccessToClosedShadowRoots")
        config.setValue(name, forKey: "name")
        guard let world = (WKContentWorld.self as AnyObject).perform(make, with: config)?.takeUnretainedValue() as? WKContentWorld else {
            return .world(name: name)
        }
        reachesClosedShadowRoots = true
        return world
    }

    /// Reports load states of every frame to the driver: `commit` when the
    /// document starts (this script runs at document start), then
    /// `domcontentloaded` and `load`, each with a token for the document. It
    /// runs in the host world, so agent code cannot forge a state.
    static let loadStateSource = """
    (() => {
      const doc = Math.random().toString(36).slice(2) + Date.now().toString(36);
      const post = (state) => { try { webkit.messageHandlers.\(loadStateHandler).postMessage({ state, doc, url: location.href, title: document.title }); } catch (e) {} };
      post("commit");
      if (document.readyState !== "loading") post("domcontentloaded");
      else document.addEventListener("DOMContentLoaded", () => post("domcontentloaded"), { once: true });
      if (document.readyState === "complete") post("load");
      else window.addEventListener("load", () => post("load"), { once: true });
    })();
    """

    /// Installs the load-state reporter (host world) and, when the host sent
    /// it, the page agent bundle (agent world) for every frame at document
    /// start. Idempotent: whatever an earlier driver installed is removed first.
    static func install(into controller: WKUserContentController, agentBundle: String?, handler: any WKScriptMessageHandler) {
        uninstall(from: controller)
        controller.addUserScript(WKUserScript(source: loadStateSource, injectionTime: .atDocumentStart,
                                              forMainFrameOnly: false, in: hostWorld))
        controller.add(handler, contentWorld: hostWorld, name: loadStateHandler)
        if let agentBundle {
            let source = agentMarker + agentBundle
            controller.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentStart,
                                                  forMainFrameOnly: false, in: world))
        }
    }

    /// Removes the driver's handler and scripts, keeping everyone else's
    /// (there is no per-world removal API).
    static func uninstall(from controller: WKUserContentController) {
        controller.removeScriptMessageHandler(forName: loadStateHandler, contentWorld: hostWorld)
        let keep = controller.userScripts.filter { $0.source != loadStateSource && !$0.source.hasPrefix(agentMarker) }
        guard keep.count != controller.userScripts.count else { return }
        controller.removeAllUserScripts()
        keep.forEach(controller.addUserScript)
    }

    /// First line of the installed agent bundle, so uninstall finds it even
    /// after the host sent a newer bundle.
    private static let agentMarker = "/* cmux-browser-automation agent */\n"

    /// Code that installs the agent in a frame that loaded before `install`,
    /// and reports whether the agent is present.
    static func ensureAgentSource(bundle: String) -> String {
        """
        if (!globalThis[Symbol.for("cmux.browserRepl.agent")]) { \(bundle) }
        return !!globalThis[Symbol.for("cmux.browserRepl.agent")];
        """
    }
}
