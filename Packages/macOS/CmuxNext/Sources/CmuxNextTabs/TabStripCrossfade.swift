import AppKit
import CmuxNextDesign

/// Reduce Motion in the tab strip: tabs take their places at once, and a tab that comes or goes
/// crossfades (motion.md rule 7) instead of vanishing or popping in. The strip's own springs
/// (width and alpha) do not run there.
@MainActor
enum TabStripCrossfade {
    /// Crossfades `clip` when the tabs `next` differ from the ones `shown`, under Reduce Motion.
    static func run(in clip: NSView, shown: Set<TabID>, next: Set<TabID>) {
        guard !Motion.animatesMovement, shown != next else { return }
        Motion.crossfadeInPlace(clip.layer)
    }
}
