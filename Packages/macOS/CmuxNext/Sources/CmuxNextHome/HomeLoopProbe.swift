import AppKit
import CmuxHomeCore
import CmuxNextDesign
import CmuxNextWakeups
import QuartzCore

/// The window side of Home's vendored loops (plans/cmux-next/chrome-parity/p14-energy.md, task 115):
/// a zero-size view that MessagesLab's transcript or conversation list adds to itself when handed
/// one as its ``LoopHost``. Its ``LoopVisibility`` sits under their window's node and follows their
/// hidden state, so the caret's blink, the typing dots and breath, and the list's typing pulse run
/// only while a person can see them, as the app's own loops do (p14-energy-056).
@MainActor final class HomeLoopProbe: NSView, LoopHost {
    private let loops: LoopVisibility

    /// - Parameter name: The node's name in diagnostics (`home.transcript.loops`).
    init(_ name: String) {
        loops = LoopVisibility(name)
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// The attached loops that are on their layers now: 0 while nobody can see them.
    var runningCount: Int { loops.runningCount }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        loops.place(in: window)
        loops.node.set(isHiddenOrHasHiddenAncestor ? .hidden : .visible)
    }

    override func viewDidHide() {
        super.viewDidHide()
        loops.node.set(.hidden)
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        loops.node.set(.visible)
    }

    func attach(_ layer: CALayer, key: String, make: @escaping @MainActor () -> CAAnimation?) {
        loops.attach(layer, key: key, make: make)
    }

    func detach(_ layer: CALayer, key: String) {
        loops.detach(layer, key: key)
    }

    func detachAll() {
        loops.detachAll()
    }
}
