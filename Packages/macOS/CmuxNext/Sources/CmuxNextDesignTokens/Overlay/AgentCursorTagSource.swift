/// What a window's agent cursor tags are and what a click on one does; the
/// app sets it on `WindowOverlayHost.agentCursorTags`. The overlay asks it on
/// pointer moves over the window and on clicks, so `agentCursorTags()` is
/// cheap and empty while no agent cursor shows.
@MainActor
public protocol AgentCursorTagSource: AnyObject {
    /// The tags a person can click now.
    func agentCursorTags() -> [AgentCursorTagTarget]
    /// A click or a VoiceOver press on the tag of cursor `id`.
    func pressAgentCursorTag(_ id: String)
    /// The pointer moved onto the tag of cursor `id`, or off every tag (nil).
    func hoverAgentCursorTag(_ id: String?)
}
