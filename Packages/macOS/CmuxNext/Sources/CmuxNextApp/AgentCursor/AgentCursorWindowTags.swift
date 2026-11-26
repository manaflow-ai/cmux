import CmuxNextAgentCursor
import CmuxNextDesign

/// One window's clickable agent cursor tags (`WindowOverlayHost.agentCursorTags`):
/// the shown tags of its cursor host that have a link (``AgentCursorTagLinks``).
@MainActor
final class AgentCursorWindowTags: AgentCursorTagSource {
    private let links: AgentCursorTagLinks
    private let host: () -> AgentCursorLayerHost?

    /// - Parameters:
    ///   - links: The app's tag links.
    ///   - host: The window's cursor host, nil until its first input draws.
    init(links: AgentCursorTagLinks, host: @escaping () -> AgentCursorLayerHost?) {
        self.links = links
        self.host = host
    }

    func agentCursorTags() -> [AgentCursorTagTarget] {
        guard let host = host() else { return [] }
        return host.tagSpots().compactMap { spot in
            guard let link = links.link(for: spot.session) else { return nil }
            return AgentCursorTagTarget(id: spot.session, frame: spot.frame, label: link.label,
                                        help: AgentCursorTagLinks.goTo(link.origin.workspaceName),
                                        accessibilityLabel: AgentCursorTagLinks.accessibilityLabel(link.label))
        }
    }

    func pressAgentCursorTag(_ id: String) {
        links.press(id)
    }

    func hoverAgentCursorTag(_ id: String?) {
        host()?.highlightTag(of: id)
    }
}
