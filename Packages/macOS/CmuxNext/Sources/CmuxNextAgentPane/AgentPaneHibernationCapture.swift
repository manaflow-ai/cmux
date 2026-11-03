import AppKit

/// Captures platform-owned wake state and its optional native cover. Eligibility remains with
/// the hibernation planner: only untouched New Tabs can reach this path without a session.
@MainActor
struct AgentPaneHibernationCapture {
    let view: AgentPaneView

    func capture(
        key: String, images: AgentPaneLaunchImages, requiresFrame: Bool,
        wake: @MainActor (AgentPaneView) async -> AgentPaneWakeState?,
        snapshot: @MainActor (AgentPaneView) async -> (image: CGImage, size: NSSize, appearance: NSAppearance.Name?)?
    ) async -> (wake: AgentPaneWakeState?, kept: String?) {
        let state = await wake(view)
        if let reason = AgentPaneWakeState.keepReason(state, hasHandshake: view.model.hasHandshake) { return (state, reason) }
        // Chromium draws over native covers. An untouched New Tab instead uses its native
        // context to rebuild. Never capture that hidden CEF surface: CEFThumbnail documents
        // the renderer-exit crash in the pinned engine's hidden capture path.
        let needsCover = requiresFrame && (view.model.newTab == nil || !view.pageDrawsOverCovers)
        // A New Tab may have become a chat while wake state was read. The default never
        // captures hidden Chromium; a new chat will stay loaded without its required cover.
        let skipsCapture = view.pageDrawsOverCovers && (view.model.newTab != nil || requiresFrame)
        let frame = skipsCapture ? nil : await snapshot(view)
        var held = false
        if let frame { held = await images.hold(key, frame.image, size: frame.size, appearance: frame.appearance) }
        return (state, needsCover && !held ? "no usable first frame" : nil)
    }
}
