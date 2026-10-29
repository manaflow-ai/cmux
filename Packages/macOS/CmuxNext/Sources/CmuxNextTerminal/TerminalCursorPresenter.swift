import CmuxNextCompat
import QuartzCore

/// The half of the terminal cursor that goes with Ghostty's frame. Ghostty calls the cursor
/// callback inside the Core Animation transaction that presents the frame the cell was drawn for, on the thread
/// that presents it (main, or the GPU completion thread for a content-only frame; ``ghosttySurfaceCursor(_:_:)``).
/// ``present(_:)`` puts the cell's pixels and place on ``Layers/cell`` in that transaction, so the text and the
/// cursor over it reach the screen in one commit, as Chromium commits the caret in the compositor frame that
/// holds its text (`cc/trees/layer_tree_host.cc`, one commit per frame).
///
/// The blink is main's (``TerminalCursorLayer``): ``present(_:)`` leaves the newest cell's ``TerminalCursorState/Blink``
/// in a one-word mailbox and asks for a main turn only when none is pending, as `ghosttyWakeup` coalesces ticks.
/// A burst of cells while main is busy costs one main turn, which applies the newest; no cell and no IOSurface
/// waits in a queue.
nonisolated final class TerminalCursorPresenter: Sendable {
    /// The cursor's two layers, each with one writer.
    // crash-allow: each layer has one writer, and Core Animation locks every property accessor: `container` (frame, opacity, animations, contentsScale) is set only on main; `cell` (contents, frame, isHidden) only by `present(_:)` inside Ghostty's present transaction, while main sets only its contentsScale, which `present(_:)` reads
    nonisolated struct Layers: @unchecked Sendable {
        /// Flipped, the size of the surface's view, over Ghostty's content; it carries the blink.
        let container: CALayer
        /// The cursor cell, placed from the container's top-left corner.
        let cell: CALayer
    }

    let layers: Layers
    private let pending = Atomic<Bool>(false)
    private let latestBlink = Atomic<UInt64>(0)

    init() {
        let container = CALayer()
        let cell = CALayer()
        container.name = "terminal.cursor"
        container.isGeometryFlipped = true
        container.anchorPoint = .zero
        cell.name = "terminal.cursor.cell"
        cell.anchorPoint = .zero
        cell.contentsGravity = .resize
        cell.isHidden = true
        // Every change applies in the transaction it is made in: the cursor jumps to its cell with its frame.
        let still = NSNull()
        let actions: [String: any CAAction] = ["contents": still, "position": still, "bounds": still, "hidden": still,
                                               "opacity": still, "contentsScale": still]
        container.actions = actions
        cell.actions = actions
        container.addSublayer(cell)
        layers = Layers(container: container, cell: cell)
    }

    /// Shows `state` on the cell layer in the caller's Core Animation transaction (Ghostty's present of the cell's
    /// frame), and leaves its blink for main. Returns true when main must take it (``takeBlink()``): no main turn
    /// is pending yet.
    // perf-hot: 5us terminal-key (three Core Animation property sets and two atomics per published cell)
    func present(_ state: TerminalCursorState) -> Bool {
        let cell = layers.cell
        cell.contents = state.image?.surface
        cell.frame = state.frame(scale: cell.contentsScale)
        cell.isHidden = !state.blink.shows
        latestBlink.store(state.blink.word, ordering: .releasing)
        return !pending.exchange(true, ordering: .acquiringAndReleasing)
    }

    /// The blink of the newest cell since the last take; nil when no cell came since.
    func takeBlink() -> TerminalCursorState.Blink? {
        guard pending.exchange(false, ordering: .acquiringAndReleasing) else { return nil }
        return TerminalCursorState.Blink(word: latestBlink.load(ordering: .acquiring))
    }
}
