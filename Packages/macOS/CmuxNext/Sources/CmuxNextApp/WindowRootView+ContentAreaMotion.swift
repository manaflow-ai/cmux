import AppKit
import CmuxNextDesign
import CmuxNextFeatures
import CmuxNextSidebar

/// The window's chrome resizing the content area over several frames. Only the
/// sidebar does this today: every frame of its width animation moves the
/// content edge, so Auto Layout resizes every pane beside it even though no
/// pane is on a layout spring of its own. Content whose resize is costly (a
/// terminal's PTY grid and shell redraw) holds it until the landing, exactly as
/// it does inside a pane's own spring (`RestingPlacement`).
extension WindowRootView {
    /// Whether the chrome is resizing the content area now. `ShellWindow`
    /// answers `ContentAreaMotionHosting` from this, and `NSView.isInPaneMotion`
    /// reads it through the window, so it holds for every view in the window.
    /// A render-server slide sized the content once in its turn and only moves
    /// it, so the content is at rest through it (`followSidebarSlide`).
    var isContentAreaInMotion: Bool { sidebar.isWidthAnimating && sidebar.widthMotionBackend == .cpuStep }

    /// The window's ``slideHoldsContent``: feature `sidebarSlideHoldsContent` of `features`.
    static func slideHoldsContent(in features: FeatureList) -> @MainActor () -> Bool {
        { features.isEnabled(.sidebarSlideHoldsContent) }
    }

    /// Tells the window's content when the sidebar's motion lands, so what held
    /// a costly resize does it once, now. The whole window and not only the
    /// content host: the motion is window-scoped, so a terminal anywhere in it
    /// held its grid and would otherwise hold it for good.
    func wireContentAreaMotion() {
        sidebar.slideFollowers = { [weak self] () -> () -> [RenderSpring.Move] in
            guard let self else { return { [] } }
            return followSidebarSlide()
        }
        sidebar.slideCanRunOnRenderServer = { [weak self] in
            guard let self else { return false }
            let beside: [NSView?] = [contentHost, rightPanel]
            return !beside.contains { $0?.subtreeDrawsInChildWindow == true }
        }
        sidebar.onWidthMotionStart = { [weak self] from, to in self?.holdContentThroughSlide(from: from, to: to) }
        sidebar.onWidthMotionChange = { [weak self] animating in
            guard !animating, let self else { return }
            // The one layout at the landed width, before the content hears the motion ended: the
            // workspace sizes its layout in `layout()` (an empty autoresizing mask), so the subtree is
            // laid out now, or a terminal would settle at the held width and report a stale grid.
            contentHost.contentHold = nil
            // sync-layout: notifyPaneMotionSettled reads the landed sizes (the comment above).
            layoutSubtreeIfNeeded()
            notifyPaneMotionSettled()
        }
    }

    /// Sizes the content once for the whole slide (GPU audit 2026-10-21, offender #1): the
    /// sidebar's width animation moves the card's edge on every frame, and a card that resized its
    /// content with it laid out every pane, terminal and Chromium page at a new width per frame. The
    /// content takes the card's widest width of the slide (its width once the sidebar is at the
    /// narrower of `from` and `to`) and rides the moving edge, so the panes slide with the sidebar
    /// as before and the card clips them at the far edge; a show lays them out once at the landing,
    /// a hide once now. A slide that turns around mid-flight keeps the widest width either leg needs.
    /// The rail style opens over the content (`WindowRootView+SidebarRail`), which never resizes:
    /// nothing to hold. The card clips the held content while it holds it, square or rounded.
    /// Feature `sidebarSlideHoldsContent` (on by default; ``slideHoldsContent``) decides, at each slide's start.
    /// A render-server slide holds nothing: the content takes its final size in the slide's one layout.
    private func holdContentThroughSlide(from: CGFloat, to: CGFloat) {
        guard slideHoldsContent(), sidebar.model.style != .rail, sidebar.widthMotionBackend == .cpuStep else {
            contentHost.contentHold = nil
            return
        }
        let widest = contentHost.bounds.width + max(0, from - to)
        contentHost.contentHold = MainPaneCardView.ContentHold(width: max(widest, contentHost.contentHold?.width ?? 0),
                                                               ridesTrailingEdge: sidebarSide == .right)
    }

    /// A render-server slide (`SidebarContainerView.slideFollowers`): notes
    /// where the window's views beside the sidebar show before the slide's one layout; the closure, called
    /// after it, springs each one the layout moved from there to rest on the sidebar's spring. The card,
    /// the title and the shade's cut-out ride the card's shift (the shade's path reaches past the window's
    /// sides, so the moved shade leaves no strip unshaded). The top row's toolbar band, its buttons and the
    /// accessories after it spring their x, width and opacity from where they showed, as each frame of the
    /// main-thread slide places them (`layout()`), and the strips under the top row spring their tabs'
    /// traffic-light inset with the card (`topRowStripsSlide`). The rail style's content sits beside the
    /// rail: the open moves nothing.
    func followSidebarSlide() -> () -> [RenderSpring.Move] {
        let cardX = contentHost.frame.minX, titleX = titlebar.frame.minX
        let topRow: [NSView?] = [toolbarBand, toolbarBand.sidebarToggle, toolbarBand.backButton, toolbarBand.forwardButton,
                                 titlebarBadge, hostPressureIndicator]
        let places = topRow.compactMap { view in view.flatMap { RenderSpring.Start($0, keys: [.positionX, .boundsWidth, .opacity]) } }
        let strips = topRowStripsSlide()
        return { [weak self] in
            guard let self else { return [] }
            let cardShift = cardX - contentHost.frame.minX, titleShift = titleX - titlebar.frame.minX
            let riders: [(CALayer?, CGFloat)] = [(contentHost.layer, cardShift), (mainPaneShade.shadeLayer, cardShift),
                                                 (titlebar.isHidden ? nil : titlebar.layer, titleShift)]
            let card: [RenderSpring.Move] = riders.compactMap { rider -> RenderSpring.Move? in
                let (layer, shift) = rider
                guard let layer, shift != 0 else { return nil }
                return RenderSpring.Move(layer, RenderSpringKey<CGFloat>.positionX, from: layer.position.x + shift, to: layer.position.x)
            }
            let topRowMoves: [RenderSpring.Move] = places.flatMap { $0.moves() }
            return card + topRowMoves + strips()
        }
    }
}
