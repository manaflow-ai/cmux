public import WebKit

/// The REPL page agent as a document-start user script in every frame's
/// agent world, so documents loaded while a session drives a tab have the
/// agent before their own scripts run. Frames that loaded earlier get it on
/// their first evaluation.
///
/// The script runs only while the agent world has the presence message
/// handler (`presenceHandlerName`), which exists while a session is attached.
@MainActor
public final class BrowserReplAgentUserScript {
    private weak var controller: WKUserContentController?

    public init() {}

    /// Adds the agent to `controller`, once per controller.
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
        guard controller !== self.controller else { return }
        self.controller = controller
        let guarded = """
        if (globalThis.webkit && webkit.messageHandlers && webkit.messageHandlers.\(presenceHandlerName)) {
        \(source)
        }
        """
        controller.addUserScript(WKUserScript(
            source: guarded,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false,
            in: world
        ))
    }

    /// Called when no session remains attached to the tab. The script stays
    /// in the controller; its guard makes it a no-op once the presence
    /// handler is removed.
    public func release() {}
}
