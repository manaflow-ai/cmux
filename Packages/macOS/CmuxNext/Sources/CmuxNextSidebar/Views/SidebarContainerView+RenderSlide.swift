import AppKit
import CmuxNextCompatAppKit
import CmuxNextDesign
import QuartzCore

/// The sidebar's show and hide on the render server (on with
/// `motion.renderServer`). The toggle's turn sets the width constant once and lays the window out once
/// at rest, so every pane, terminal grid and page takes its final size now, once. One group of
/// additive `RenderSpring`s then carries what moved from where it showed: the clip's frame, the panel in
/// it, the resize handle and the window's views beside the sidebar (`slideFollowers`). The fade variant
/// fades the panel on its own short fade token, as the main-thread slide does. No display frame steps
/// the slide and nothing lays out again for it. This is Chrome's compositor model: layout is final at
/// once and the compositor animates the layers (`ui/compositor/layer_animator.h`,
/// `cc/animation/keyframe_model.h`).
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

    /// Runs the pending slide (`pendingSlide`) on the render server. False when there is none, while a
    /// main-thread slide runs (it keeps its backend to its landing, so a retarget starts from what it
    /// shows), or while the window shows content a layer spring cannot carry (`slideCanRunOnRenderServer`).
    func slideOnRenderServer() -> Bool {
        guard let slide = pendingSlide, !(isWidthAnimating && widthMotionBackend == .cpuStep), slideCanRunOnRenderServer() else {
            return false
        }
        let host = superview ?? self
        widthMotionBackend = .renderServer
        // What shows now: the model values the springs start from.
        let containerX = frame.minX
        let clipX = clip.layer?.position.x, clipWidth = clip.layer?.bounds.width
        let panelX = panel.layer?.position.x
        // A fade into a panel at rest collapsed starts transparent, as the main-thread fade does; a shown
        // panel whose width does not change (a variant switch) does not blink. Otherwise the fade starts
        // from the opacity on screen.
        let fadesIn = slide.fadesPanel && !slide.hidden && !isWidthAnimating && widthConstraint.constant != slide.to
        let shownOpacity: CGFloat? = fadesIn ? 0 : panel.layer.map { CGFloat(($0.presentation() ?? $0).opacity) }
        let handleX = handle.convert(handle.bounds, to: host).minX
        let followers = slideFollowers?()
        isWidthAnimating = true
        onWidthMotionStart?(frame.width, slide.to)
        widthCompletedGeneration = nil
        fadeCompletedGeneration = slide.fadesPanel ? nil : slide.generation
        widthConstraint.constant = slide.to
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
        moves += followers?() ?? []
        renderSlideSprings += moves.map { (layer: $0.layer, keyPath: $0.keyPath) }
        let token: MotionSpring = slide.hidden ? .disappear : .appear
        armWidthMotionWatchdog(token)
        let generation = slide.generation, hidden = slide.hidden, fadesPanel = slide.fadesPanel
        Motion.sidebar.renderSpring(token).animateGroup(moves, in: self) { [weak self] finished in
            guard finished else { return }
            self?.finishRenderSlide(generation: generation, hidden: hidden, fadesPanel: fadesPanel)
        }
        if slide.fadesPanel {
            fadePanel(hidden: slide.hidden, from: shownOpacity, generation: generation)
        } else {
            // The plain slide shows the panel opaque at once, as the main-thread slide does.
            panel.layer?.removeAnimation(forKey: slideOpacity.path)
            panel.alphaValue = 1
        }
        return true
    }

    /// The slide-and-fade variant's opacity leg: the panel fades from `start` on the short fade tokens, not
    /// over the slide's full travel, as the main-thread slide's fade does. One timed fade on the render
    /// server; its landing ends the leg (`finishRenderFade`).
    private func fadePanel(hidden: Bool, from start: CGFloat?, generation: Int) {
        let token: MotionFade = hidden ? .fadeOut : .fadeIn
        let opacity: CGFloat = hidden ? 0 : 1
        panel.alphaValue = opacity
        guard let layer = panel.layer, let start, start != opacity, Motion.canAnimate(in: self), Motion.sidebar.duration(token) > 0 else {
            panel.layer?.removeAnimation(forKey: slideOpacity.path)
            return finishRenderFade(generation: generation, hidden: hidden)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setMainCompletion { [weak self] in self?.finishRenderFade(generation: generation, hidden: hidden) }
        Motion.sidebar.set(layer, slideOpacity.path, to: Float(opacity), fade: token, from: Float(start))
        CATransaction.commit()
    }

    /// Removes the render-server slides' springs, the window's followers' too, and the panel's fade, so
    /// every layer shows its model value now (`snap()`, a resize drag, a main-thread slide taking over).
    /// Returns the sidebar's width on screen when a slide was running, else nil; the caller makes its
    /// landings stale (`animationGeneration`). A main-thread slide's animators are not touched.
    @discardableResult
    func stopRenderSlide() -> CGFloat? {
        guard widthMotionBackend == .renderServer,
              !renderSlideSprings.isEmpty || panel.layer?.animation(forKey: slideOpacity.path) != nil else { return nil }
        let shown = clip.layer.map { ($0.presentation() ?? $0).bounds.width } ?? frame.width
        for spring in renderSlideSprings { RenderSpring.stop(spring.layer, spring.keyPath) }
        renderSlideSprings = []
        panel.layer?.removeAnimation(forKey: slideOpacity.path)
        return shown
    }
}
