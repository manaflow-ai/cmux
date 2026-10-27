import AppKit
import CmuxNextDesign

/// The root's motion backends: the screen switch and the drop highlight (``RenderMotionKind``).
extension LayoutRootView {
    /// The root's render-server motion variants, one per kind, in the order their motions start. A
    /// task that moves one of the root's kinds to the render server writes its variant in its own
    /// file and adds its one line here; with none listed, or `motion.renderServer` off (the
    /// default), the screen frames and the highlight step on the main thread in `advanceFrame`.
    static var renderServerMotions: [any RenderServerMotion<LayoutRootView>] { [DropHighlightRenderMotion()] }

    /// Ends a change turn of the root (a screen switch, a drop-highlight show, move or hide), after
    /// it set its targets and before the caller places the screens: the render-server kinds take
    /// their motions. Returns whether the CPU still needs display frames: `needsFrames`, less the
    /// motions the render server took.
    func endMotionTurn(needsFrames: Bool) -> Bool {
        guard !motionBackends.begin(on: self, policy: Motion.panes.policy).isEmpty else { return needsFrames }
        let screensMoving = screenFrames.values.contains { $0.rect != $0.targetRect || $0.alpha.value != $0.alpha.target }
        return needsFrames && (screensMoving || highlight.isMoving)
    }

    /// A drop-highlight change (`DropHighlightView.show`, `hide`) that returned `needsFrames`: its
    /// change turn, then display frames for what still steps on the main thread. A move of a
    /// self-driven style the render server did not take shows with the style's own Core Animation
    /// springs (``DropHighlightView/commitOwnMove(onRenderServer:)``).
    func highlightChanged(needsFrames: Bool) {
        let frames = endMotionTurn(needsFrames: needsFrames)
        highlight.commitOwnMove(onRenderServer: false)
        if frames { driver.start() }
    }

    /// The display frames step the drop highlight: always with `motion.renderServer` off (as before);
    /// on, only a style the CPU draws while it moves. A self-driven style's moves run on the render
    /// server (``DropHighlightRenderMotion``), so a drag across zones takes no frame step.
    var highlightStepsOnFrames: Bool { highlight.isMoving || !motionBackends.isLive }
}
