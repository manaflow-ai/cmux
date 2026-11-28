public import WebKit

/// One session's page agent as a document-start user script in every
/// frame of a tab, in that session's agent world
/// (``BrowserReplSessionWorld``), so documents loaded while the session
/// drives the tab have the agent before their own scripts run. Frames that
/// loaded earlier get it on their first evaluation.
///
/// The script runs only while its world has the presence message handler
/// (`presenceHandlerName`), which this installer adds with it. A controller
/// holds at most one copy per world, whichever installer added it, and the
/// copy (with its handler) leaves the controller when the last installer
/// for that world releases it or moves to another controller. Other user
/// scripts, and other sessions' agents, stay.
@MainActor
public final class BrowserReplAgentUserScript {
    /// One world's agent script in one controller, and how many installers
    /// hold it.
    private final class Installed {
        let script: WKUserScript
        let world: WKContentWorld
        let presenceHandlerName: String
        var holders = 1

        init(script: WKUserScript, world: WKContentWorld, presenceHandlerName: String) {
            self.script = script
            self.world = world
            self.presenceHandlerName = presenceHandlerName
        }
    }

    /// Each controller's agent scripts by world name.
    private final class ControllerScripts {
        var byWorld: [String: Installed] = [:]
    }

    private static let controllers = NSMapTable<WKUserContentController, ControllerScripts>.weakToStrongObjects()

    private weak var controller: WKUserContentController?
    private var worldName: String?

    public init() {}

    /// Adds the agent for `world` to `controller` unless it already has it,
    /// and releases what this installer held before in another controller
    /// or world.
    /// - Parameters:
    ///   - source: The page agent's install source.
    ///   - presenceHandlerName: The agent-world message handler whose
    ///     presence lets the script run; added with the script.
    ///   - world: The session's agent world.
    ///   - controller: The tab's user content controller.
    public func install(
        source: String,
        presenceHandlerName: String,
        world: WKContentWorld,
        in controller: WKUserContentController
    ) {
        let name = world.name ?? ""
        if self.controller === controller, worldName == name { return }
        release()
        self.controller = controller
        worldName = name
        let scripts = Self.controllers.object(forKey: controller) ?? {
            let made = ControllerScripts()
            Self.controllers.setObject(made, forKey: controller)
            return made
        }()
        if let installed = scripts.byWorld[name] {
            installed.holders += 1
            return
        }
        let guarded = """
        if (globalThis.webkit && webkit.messageHandlers && webkit.messageHandlers.\(presenceHandlerName)) {
        \(source)
        }
        """
        let script = WKUserScript(
            source: guarded,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false,
            in: world
        )
        scripts.byWorld[name] = Installed(script: script, world: world, presenceHandlerName: presenceHandlerName)
        controller.addUserScript(script)
        controller.add(PresenceHandler(), contentWorld: world, name: presenceHandlerName)
    }

    /// Lets go of the agent this installer added or shared; the last
    /// holder of a world's agent removes it and its presence handler.
    public func release() {
        defer {
            controller = nil
            worldName = nil
        }
        guard let controller, let worldName,
              let scripts = Self.controllers.object(forKey: controller),
              let installed = scripts.byWorld[worldName] else { return }
        installed.holders -= 1
        guard installed.holders == 0 else { return }
        scripts.byWorld[worldName] = nil
        controller.removeScriptMessageHandler(forName: installed.presenceHandlerName, contentWorld: installed.world)
        // WebKit removes user scripts only all at once, so every other
        // script is added again, in order. `userScripts` is a live view of
        // the controller's list, so it is copied first.
        let kept = controller.userScripts.map { $0 }.filter { $0 !== installed.script }
        controller.removeAllUserScripts()
        for script in kept { controller.addUserScript(script) }
    }

    /// Marks, in an agent world, that its session is attached; the agent's
    /// document-start script installs itself only while it exists.
    @MainActor
    private final class PresenceHandler: NSObject, WKScriptMessageHandler {
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {}
    }
}
