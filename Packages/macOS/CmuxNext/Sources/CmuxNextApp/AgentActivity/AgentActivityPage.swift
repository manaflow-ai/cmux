import CmuxNextAgentActivity
import CmuxNextPages
import Foundation

extension PageDescriptor {
    /// The Agent Activity page (computer use sessions and their steps) on the shared page host, so
    /// it follows `browser.defaultEngine` like every cmux page. Its files ship in
    /// CmuxNextAgentActivity's bundle (``registerAgentActivityRoot()``); it is not first-party, so it
    /// gets the strict CSP and no daemon link.
    static let agentActivity = PageDescriptor(id: "cmux.agent-activity", resource: "agent-activity",
                                              namespaces: [AgentActivityPageProvider.prefix], acceptsFirstMouse: false)

    /// Names the page's bundled folder for both engines; call once at launch, before Chromium's
    /// scheme table is made (`FirstPartyPageSchemes.install`).
    @discardableResult
    static func registerAgentActivityRoot() -> URL? {
        guard let root = AgentActivityHostView.bundledPage?.deletingLastPathComponent() else { return nil }
        PageID.registerBundledRoot(root, for: agentActivity.id)
        return root
    }
}
