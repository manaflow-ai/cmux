import AppKit
import CmuxNextDesign
import QuartzCore

/// The sidebar's show and hide on the render server (chrome-parity p03-rendering-100, on with
/// `motion.renderServer`). The toggle's turn sets the width constant once and lays the window out once
/// at rest, so every pane, terminal grid and page takes its final size now, once. One group of
/// additive `RenderSpring`s then carries what moved from where it showed: the clip's frame, the panel in
/// it, the resize handle and the window's views beside the sidebar (`slideFollowers`); the fade variant
/// springs the panel's opacity in the same group. No display frame steps the slide and nothing lays out
/// again for it. This is Chrome's compositor model: layout is final at once and the compositor animates
/// the layers (`ui/compositor/layer_animator.h`, `cc/animation/keyframe_model.h`).
struct SidebarSlideRenderMotion: RenderServerMotion {
    var kind: RenderMotionKind { .sidebarSlide }

    func begin(on sidebar: SidebarContainerView, policy: MotionPolicy) -> MotionBackend {
        sidebar.slideOnRenderServer() ? .renderServer : .cpuStep
    }
}

/// The slide one `apply()` starts.
struct SidebarSlide {
    /// The width the sidebar rests at.
    let to: CGFloat
    /// The panel collapses (hide, or the rail closing).
    let hidden: Bool
    /// The slide-and-fade variant (`SidebarCollapseMotionVariant.fadesPanel`).
    let fadesPanel: Bool
    /// The slide's `animationGeneration`; a newer slide makes this one's landing do nothing.
    let generation: Int
}

extension SidebarContainerView {
    /// The sidebar's render-server variants, one per kind (``RenderMotionKind``).
    static var renderServerMotions: [any RenderServerMotion<SidebarContainerView>] { [SidebarSlideRenderMotion()] }

    /// The keys a render-server slide springs on the sidebar's own layers.
    private var slideX: RenderSpringKey<CGFloat> { .positionX }
    private var slideWidth: RenderSpringKey<CGFloat> { .boundsWidth }
    private var slideOpacity: RenderSpringKey<CGFloat> { .opacity }

    /// Runs the pending slide (`pendingSlide`) on the render server. False when there is none.
    func slideOnRenderServer() -> Bool {
        guard let slide = pendingSlide else { return false }
        let host = superview ?? self
        if isWidthAnimating, widthMotionBackend == .cpuStep { stopMainThreadSlide() }
        widthMotionBackend = .renderServer
        // What shows now: the model values the springs start from.
        let containerX = frame.minX
        let clipX = clip.layer?.position.x, clipWidth = clip.layer?.bounds.width
        let panelX = panel.layer?.position.x
        // A fade into a panel at rest collapsed starts transparent, as the main-thread fade does; a shown
        // panel whose width does not change (a variant switch) does not blink.
        let fadesIn = slide.fadesPanel && !slide.hidden && !isWidthAnimating && widthConstraint.constant != slide.to
        let panelOpacity = fadesIn ? 0 : panel.layer.map { CGFloat($0.opacity) }
        let handleX = handle.convert(handle.bounds, to: host).minX
        let followers = slideFollowers?()
        isWidthAnimating = true
        onWidthMotionStart?(frame.width, slide.to)
        let opacity: CGFloat = slide.fadesPanel && slide.hidden ? 0 : 1
        widthConstraint.constant = slide.to
        panel.alphaValue = opacity
        // sync-layout: the slide's one layout; each spring starts from the frame it replaced.
        host.layoutSubtreeIfNeeded()
        var moves: [RenderSpring.Move] = []
        func spring(_ layer: CALayer?, _ key: RenderSpringKey<CGFloat>, from: CGFloat?) {
            guard let layer, let from, let rest = key.value(of: layer), from != rest else { return }
            moves.append(RenderSpring.Move(layer, key, from: from, to: rest))
        }
        // The clip's parent moved by the container's shift; the panel's parent is the clip, springing with it.
        spring(clip.layer, slideX, from: clipX.map { $0 + containerX - frame.minX })
        spring(clip.layer, slideWidth, from: clipWidth)
        spring(panel.layer, slideX, from: panelX)
        let handleShift = handleX - handle.convert(handle.bounds, to: host).minX
        spring(handle.layer, slideX, from: handle.layer.map { $0.position.x + handleShift })
        spring(panel.layer, slideOpacity, from: panelOpacity)
        moves += followers?() ?? []
        let token: MotionSpring = slide.hidden ? .disappear : .appear
        armWidthMotionWatchdog(token)
        let generation = slide.generation, hidden = slide.hidden, fadesPanel = slide.fadesPanel
        Motion.sidebar.renderSpring(token).animateGroup(moves, in: self) { [weak self] finished in
            guard finished else { return }
            self?.finishRenderSlide(generation: generation, hidden: hidden, fadesPanel: fadesPanel)
        }
        return true
    }

    /// A main-thread slide still running hands over to the render server: its animators stop where they
    /// show, so the springs start from there.
    private func stopMainThreadSlide() {
        Motion.withoutAnimation {
            Motion.animator(widthConstraint, in: self).constant = widthConstraint.constant
            panel.animator().alphaValue = panel.alphaValue
        }
    }

    /// Removes a render-server slide's springs from the sidebar's own layers, which show their model
    /// values now (`snap()`).
    func stopRenderSlide() {
        for layer in [clip.layer, panel.layer, handle.layer].compactMap(\.self) {
            for path in [slideX.path, slideWidth.path, slideOpacity.path] { RenderSpring.stop(layer, path) }
        }
    }
}
