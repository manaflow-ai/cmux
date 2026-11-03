public import AppKit
public import CmuxNextDesign
import CmuxNextControl

extension AgentPaneView {
    /// An image of the page as shown (the next launch draws it until this
    /// page paints again, and so does a released page built again,
    /// `AgentPageHibernation`); nil when no picture can stand in for it
    /// (``PageImageBackground/cover(_:color:pageIsOpaque:keepsClearAreas:)``).
    public func pageImage() async -> NSImage? {
        // Read before and after: the page can move to or from Chromium while its picture is taken.
        guard snapshotKeepsClearAreas || Self.pageIsOpaque(surfaceKind, in: self) else { return nil }
        let image = await snapshotPage()
        let under = performWithTheme { AgentPaneTheme.underPageColor(themeTokens, surface: surfaceKind) }
        return PageImageBackground.cover(image, color: under, pageIsOpaque: Self.pageIsOpaque(surfaceKind, in: self),
                                         keepsClearAreas: snapshotKeepsClearAreas)
    }

    /// A bounded, appearance-tagged frame for hidden-page hibernation. The caller retains the
    /// page if this cannot produce the snapshot that covers its next first frame.
    public func hibernationFrame() async -> (image: CGImage, size: NSSize, appearance: NSAppearance.Name?)? {
        let appearance = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])
        let frame = try? await ControlDeadline.shared.run(method: "hibernation.agentSnapshot", deadline: .now + .seconds(2)) { @MainActor in
            await self.pageImage().flatMap { image in image.cgImage(forProposedRect: nil, context: nil, hints: nil).map { ($0, image.size, appearance) } }
        }
        return frame.flatMap { $0 }
    }

    public var isOnScreenForHibernation: Bool { window != nil && !isHiddenOrHasHiddenAncestor }

    /// Capture the page-owned state and encode its first-frame cover before the native store
    /// removes this view. The store must recheck page identity, visibility and activity afterwards.
    public func captureForHibernation(
        key: String, images: AgentPaneLaunchImages, requiresFrame: Bool,
        wake: @MainActor (AgentPaneView) async -> AgentPaneWakeState?,
        snapshot: @MainActor (AgentPaneView) async -> (image: CGImage, size: NSSize, appearance: NSAppearance.Name?)?
    ) async -> (wake: AgentPaneWakeState?, kept: String?) {
        let state = await wake(self)
        if let reason = AgentPaneWakeState.keepReason(state, hasHandshake: model.hasHandshake) { return (state, reason) }
        let frame = await snapshot(self)
        var held = false
        if let frame { held = await images.hold(key, frame.image, size: frame.size, appearance: frame.appearance) }
        return (state, requiresFrame && !held ? "no usable first frame" : nil)
    }

    /// Whether a saved picture of a page (`AgentPaneLaunchImages`) may stand in for it under the
    /// pane: one that keeps clear pixels always, one with no alpha only when the page paints an
    /// opaque background. The draw side of ``pageImage()``'s rule, so a picture an older version saved
    /// (a Chromium JPEG of a see-through page, black where the page is clear) is never drawn by the
    /// first launch after an update.
    ///
    /// - Parameters:
    ///   - image: The saved picture.
    ///   - newTab: Whether the page is a New Tab page (its tab's record, known before its view is
    ///     made: a launch that defers the tab draws its picture first).
    ///   - scope: The view whose theme scope the page shows in (its pane): a workspace's own
    ///     picture or glass makes its pages clear.
    public static func savedPictureCovers(_ image: NSImage, newTab: Bool, in scope: NSView) -> Bool {
        PageImageBackground.covers(image, pageIsOpaque: pageIsOpaque(newTab ? .newTabPage : .agentPane, in: scope))
    }

    /// Whether the page of `surface` paints an opaque background of its own in `scope`'s theme
    /// scope (`performWithTheme`).
    private static func pageIsOpaque(_ surface: SurfaceKind, in scope: NSView) -> Bool {
        scope.performWithTheme { PageImageBackground.isOpaque(AgentPaneTheme.pageBackground(scope.themeTokens, surface: surface)) }
    }
}

extension AgentPaneLaunchImages {
    /// `key`'s last page (``take(_:size:appearance:)``) when it may stand in for the page in `scope`
    /// (``AgentPaneView/savedPictureCovers(_:newTab:in:)``): a saved picture with no alpha over a page that is clear
    /// now (an older version's Chromium JPEG of a see-through page) is black where the page is clear, so it is nil
    /// and the pane shows its loading state instead.
    public func takeCovering(_ key: String, newTab: Bool, size: NSSize, appearance: NSAppearance.Name?, in scope: NSView) -> NSImage? {
        take(key, size: size, appearance: appearance).flatMap { AgentPaneView.savedPictureCovers($0, newTab: newTab, in: scope) ? $0 : nil }
    }
}
