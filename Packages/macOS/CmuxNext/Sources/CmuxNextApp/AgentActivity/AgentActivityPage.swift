import CmuxNextAgentActivity
import CmuxNextPages
import Foundation

extension PageDescriptor {
    /// The Agent Activity page (computer use sessions and their steps) on the shared page host, so
    /// it follows `browser.defaultEngine` like every cmux page. Its files ship in
    /// CmuxNextAgentActivity's bundle (``registerAgentActivityRoot(overlay:)``); it is not first-party, so it
    /// gets the strict CSP and no daemon link.
    static let agentActivity = PageDescriptor(id: "cmux.agent-activity", resource: "agent-activity", processGroup: .solo,
                                              namespaces: [AgentActivityPageProvider.prefix], acceptsFirstMouse: false,
                                              opTables: [AgentActivityPageProvider.ops])

    /// Names the page's bundled folder for both engines, and where it sits in a web update, so the page
    /// comes from the same update as the shared React it imports (`WebBundleOverlay`); call once at
    /// launch, before Chromium's scheme table is made (`FirstPartyPageSchemes.install`).
    @discardableResult
    static func registerAgentActivityRoot(overlay: WebBundleOverlay = .shared) -> URL? {
        guard let root = AgentActivityPageAddress.bundledPage?.deletingLastPathComponent() else { return nil }
        PageID.registerBundledRoot(root, for: agentActivity.id)
        overlay.register(bundled: root, output: WebBundleOverlay.agentActivityOutput)
        return root
    }
}
