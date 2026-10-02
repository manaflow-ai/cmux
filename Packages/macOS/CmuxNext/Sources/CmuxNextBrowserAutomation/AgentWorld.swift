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
    /// `domcontentloaded` and `load`.
    static let loadStateSource = """
    (() => {
      const post = (state) => { try { webkit.messageHandlers.\(loadStateHandler).postMessage({ state, url: location.href, title: document.title }); } catch (e) {} };
      post("commit");
      if (document.readyState !== "loading") post("domcontentloaded");
      else document.addEventListener("DOMContentLoaded", () => post("domcontentloaded"), { once: true });
      if (document.readyState === "complete") post("load");
      else window.addEventListener("load", () => post("load"), { once: true });
    })();
    """

    /// Installs the load-state reporter and, when the host sent it, the page
    /// agent bundle into `controller` for every frame at document start.
    static func install(into controller: WKUserContentController, agentBundle: String?, handler: any WKScriptMessageHandler) {
        controller.addUserScript(WKUserScript(source: loadStateSource, injectionTime: .atDocumentStart,
                                              forMainFrameOnly: false, in: world))
        controller.add(handler, contentWorld: world, name: loadStateHandler)
        if let agentBundle {
            controller.addUserScript(WKUserScript(source: agentBundle, injectionTime: .atDocumentStart,
                                                  forMainFrameOnly: false, in: world))
        }
    }

    /// Code that installs the agent in a frame that loaded before `install`,
    /// and reports whether the agent is present.
    static func ensureAgentSource(bundle: String) -> String {
        """
        if (!globalThis[Symbol.for("cmux.browserRepl.agent")]) { \(bundle) }
        return !!globalThis[Symbol.for("cmux.browserRepl.agent")];
        """
    }
}
