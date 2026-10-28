import CmuxNextDesign

/// The tab-drop highlight on the render server (chrome-parity R2; on with
/// `motion.renderServer`). A drag event that moves the target hands the move to Core Animation at the
/// end of its change turn as one additive `RenderSpring` retarget of the outline ring
/// (``DropHighlightView/commitOwnMove(onRenderServer:)``): the spring keeps its velocity across zones,
/// nothing reads the presentation layer, and the main thread steps no display frame for it. Chromium
/// retargets a running compositor animation on input the same way
/// (`cc/animation/scroll_offset_animation_curve.cc`, `UpdateTarget`). A style that redraws its paths
/// from the rect stays on the CPU springs (``MotionBackend/cpuStep``).
struct DropHighlightRenderMotion: RenderServerMotion {
    var kind: RenderMotionKind { .dropHighlight }

    func begin(on root: LayoutRootView, policy: MotionPolicy) -> MotionBackend {
        root.highlight.commitOwnMove(onRenderServer: true) ? .renderServer : .cpuStep
    }
}
