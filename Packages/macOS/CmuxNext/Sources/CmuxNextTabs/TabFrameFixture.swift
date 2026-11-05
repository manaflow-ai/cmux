import AppKit
import CmuxNextCompat
import CmuxNextDesign
import QuartzCore

/// FRAME OWNER REFACTOR film fixture (Debug Settings `motion.frameOwner.tabOutline`, DEBUG and bench builds only): a
/// 1 device-pixel #FFFF00 border on every tab cell's root layer of one strip, so a 120 Hz film finds each tab's edges in
/// each frame and judges them against its pane's edge. A layer border draws inside the bounds: no frame or layout
/// changes, no animation. Outside DEBUG and bench builds it does nothing.
@MainActor
final class TabFrameFixture {
    private weak var strip: TabStripView?
    private var observation: Task<Void, Never>?

    init(strip: TabStripView) {
        self.strip = strip
    }

    /// Outlines `cell` (or takes the outline off), without implicit animation.
    func outline(_ cell: TabCell) {
        let width = borderWidth
        guard cell.layer.borderWidth != width else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        cell.layer.borderWidth = width
        cell.layer.borderColor = width > 0 ? CGColor(red: 1, green: 1, blue: 0, alpha: 1) : nil
        CATransaction.commit()
    }

    /// Follows the Debug switch while the strip is in a window (no task outside DEBUG and bench builds).
    func start() {
        #if DEBUG || CMUX_BENCH_HOOKS
        guard observation == nil else { return }
        observation = Task { [weak self] in
            for await _ in ObservationStream({ DesignTunables.frameOwnerTabOutline.value }) {
                guard let self, let strip = self.strip else { return }
                for cell in strip.cells.values { self.outline(cell) }
            }
        }
        #endif
    }

    func stop() {
        observation?.cancel()
        observation = nil
    }

    /// One device pixel of the strip's window; 0 with the fixture off.
    private var borderWidth: CGFloat {
        #if DEBUG || CMUX_BENCH_HOOKS
        DesignTunables.frameOwnerTabOutline.value ? 1 / max(strip?.window?.backingScaleFactor ?? 2, 1) : 0
        #else
        0
        #endif
    }
}
