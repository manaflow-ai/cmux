public import WebKit

/// The REPL page agent as a document-start user script in every frame's
/// agent world, so documents loaded while a session drives a tab have the
/// agent before their own scripts run. Frames that loaded earlier get it on
/// their first evaluation.
///
/// The script runs only while the agent world has the presence message
/// handler (`presenceHandlerName`), which exists while a session is attached.
/// A controller holds at most one copy, whichever attachment installed it,
/// and the copy leaves the controller when the tab's last session detaches
/// or the tab moves to another web view. Other user scripts stay.
@MainActor
public final class BrowserReplAgentUserScript {
    /// Every agent script this process created, to tell them apart from the
    /// controller's other user scripts.
    private static let agentScripts = NSHashTable<WKUserScript>.weakObjects()

    private weak var controller: WKUserContentController?

    public init() {}

    /// Adds the agent to `controller` unless it already has it, and removes
    /// it from the controller this installer used before.
    /// - Parameters:
    ///   - source: The page agent's install source.
    ///   - presenceHandlerName: The agent-world message handler whose
    ///     presence lets the script run.
    ///   - world: The agent's content world.
    ///   - controller: The tab's user content controller.
    public func install(
        source: String,
        presenceHandlerName: String,
        world: WKContentWorld,
        in controller: WKUserContentController
    ) {
        if let previous = self.controller, previous !== controller {
            Self.remove(from: previous)
        }
        self.controller = controller
        guard !controller.userScripts.contains(where: Self.agentScripts.contains) else { return }
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
        Self.agentScripts.add(script)
        controller.addUserScript(script)
    }

    /// Removes the agent from the controller; called when no session
    /// remains attached to the tab.
    public func release() {
        if let controller { Self.remove(from: controller) }
        controller = nil
    }

    /// WebKit removes user scripts only all at once, so this re-adds every
    /// script that is not the agent, in order. `userScripts` is a live view
    /// of the controller's list, so it is copied first.
    private static func remove(from controller: WKUserContentController) {
        let scripts = controller.userScripts.map { $0 }
        guard scripts.contains(where: agentScripts.contains) else { return }
        controller.removeAllUserScripts()
        for script in scripts where !agentScripts.contains(script) {
            controller.addUserScript(script)
        }
    }
}
