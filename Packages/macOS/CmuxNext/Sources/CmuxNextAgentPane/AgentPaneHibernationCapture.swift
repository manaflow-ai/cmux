public import AppKit
import CmuxNextControl

/// Captures platform-owned wake state and its optional native cover. Eligibility remains with
/// the hibernation planner: only untouched New Tabs can reach this path without a session.
@MainActor
public struct AgentPaneHibernationCapture {
    let view: AgentPaneView

    /// The hidden page whose platform state and frame may be retained.
    public init(view: AgentPaneView) { self.view = view }

    /// Whether the page is still mounted where the user can see it.
    public var isOnScreen: Bool { view.window != nil && !view.isHiddenOrHasHiddenAncestor }

    /// A bounded, appearance-tagged frame for hidden-page hibernation. The caller retains the
    /// page if this cannot produce the snapshot that covers its next first frame.
    public func frame() async -> (image: CGImage, size: NSSize, appearance: NSAppearance.Name?)? {
        let appearance = view.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])
        let frame = try? await ControlDeadline.shared.run(method: "hibernation.agentSnapshot", deadline: .now + .seconds(2)) { @MainActor in
            await self.view.pageImage().flatMap { image in image.cgImage(forProposedRect: nil, context: nil, hints: nil).map { ($0, image.size, appearance) } }
        }
        return frame.flatMap { $0 }
    }

    /// Reads restorable state and holds a usable cover when the page's engine can draw it.
    public func capture(
        key: String, images: AgentPaneLaunchImages, requiresFrame: Bool,
        wake: @MainActor (AgentPaneView) async -> AgentPaneWakeState?,
        snapshot: @MainActor (AgentPaneView) async -> (image: CGImage, size: NSSize, appearance: NSAppearance.Name?)?
    ) async -> (wake: AgentPaneWakeState?, kept: String?) {
        let wasNewTab = view.model.newTab != nil
        let state = await wake(view)
        if let reason = AgentPaneWakeState.keepReason(state, hasHandshake: view.model.hasHandshake) { return (state, reason) }
        // Chromium draws over native covers. An untouched New Tab instead uses its native
        // context to rebuild. Never capture that hidden CEF surface: CEFThumbnail documents
        // the renderer-exit crash in the pinned engine's hidden capture path.
        let needsCover = requiresFrame && (view.model.newTab == nil || !view.pageDrawsOverCovers)
        // A New Tab may have become a chat while wake state was read. The default never
        // captures hidden Chromium; a new chat will stay loaded without its required cover.
        let skipsCapture = view.pageDrawsOverCovers && (wasNewTab || view.model.newTab != nil || requiresFrame)
        let frame = skipsCapture ? nil : await snapshot(view)
        var held = false
        if let frame { held = await images.hold(key, frame.image, size: frame.size, appearance: frame.appearance) }
        return (state, needsCover && !held ? "no usable first frame" : nil)
    }
}
