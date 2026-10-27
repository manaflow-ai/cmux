public import SwiftUI
import AppKit
import CmuxNextWakeups
import Observation

/// SwiftUI's infinite loops, the one place cmux writes them (plans/cmux-next/chrome-parity/p14-energy.md,
/// task 115; `wakeup-audit.py`'s `swiftui-loop` rule refuses them anywhere else): an indefinite
/// symbol effect and an indeterminate progress bar. Each runs only while its gate's loops are on
/// (Reduce Motion, Energy Saver, the category switch) and its window shows: a hidden or occluded
/// window, a miniaturized one or a hidden app keeps the effect still, as ``LoopVisibility`` keeps
/// the app's Core Animation loops off their layers. Chromium stops a hidden page's animations the
/// same way (`content/browser/web_contents/web_contents_impl.cc`, `WasHidden` / `WasOccluded`).
public extension View {
    /// Rotates the symbol (macOS 15 and newer; a pulse on macOS 14, which has no rotate effect)
    /// while `isActive`, the gate's loops are on and the window shows; still otherwise.
    /// - Parameters:
    ///   - isActive: The work it shows is under way.
    ///   - gate: The motion gate whose loops it follows.
    func indeterminateSymbolEffect(isActive: Bool, gate: MotionGate = Motion.indicators) -> some View {
        modifier(IndeterminateSymbolLoop(isActive: isActive, gate: gate))
    }
}

/// A linear progress bar for work of unknown length: the system's moving bar while the gate's
/// loops are on and the window shows, an empty still track otherwise.
public struct IndeterminateProgressBar: View {
    private let gate: MotionGate
    @State private var window = WindowShownProbe.Shown()

    /// - Parameter gate: The motion gate whose loops it follows.
    public init(gate: MotionGate = Motion.indicators) {
        self.gate = gate
    }

    public var body: some View {
        Group {
            if window.isShown && gate.animatesLoops {
                // motion: allow the bar moves only while gate.animatesLoops and its window shows
                ProgressView().progressViewStyle(.linear)
            } else {
                ProgressView(value: 0).progressViewStyle(.linear)
            }
        }
        .background(WindowShownProbe(shown: window))
    }
}

/// The symbol effect of `indeterminateSymbolEffect(isActive:gate:)`. The body reads `gate` through
/// Observation (``AppearanceSignals``), so a motion change re-runs it.
private struct IndeterminateSymbolLoop: ViewModifier {
    let isActive: Bool
    let gate: MotionGate
    @State private var window = WindowShownProbe.Shown()

    func body(content: Content) -> some View {
        let runs = isActive && window.isShown && gate.animatesLoops
        return Group {
            if #available(macOS 15, *) {
                // motion: allow the effect runs only while gate.animatesLoops and its window shows (`runs`)
                content.symbolEffect(.rotate, isActive: runs)
            } else {
                // motion: allow the effect runs only while gate.animatesLoops and its window shows (`runs`)
                content.symbolEffect(.pulse, isActive: runs)
            }
        }
        .background(WindowShownProbe(shown: window))
    }
}

/// A zero-size view behind the effect that puts it in the visibility tree (``ViewVisibility``) and
/// writes its node's flips to ``Shown``. Internal so tests can host it.
struct WindowShownProbe: NSViewRepresentable {
    /// Whether the view's window shows, as its probe last saw it.
    @MainActor @Observable final class Shown {
        var isShown = false
    }

    let shown: Shown

    func makeNSView(context: Context) -> ProbeView { ProbeView(shown: shown) }
    func updateNSView(_ view: ProbeView, context: Context) {}

    final class ProbeView: NSView {
        private let shown: Shown
        private let visibility = ViewVisibility("swiftui.loop")
        private var flips: VisibilitySubscription?
        /// The probe's place in the visibility tree (recipe R-hide).
        private var node: VisibilityNode { visibility.node }

        init(shown: Shown) {
            self.shown = shown
            super.init(frame: .zero)
            flips = node.subscribe(owner: "VisibleLoopEffects") { [weak self] _ in self?.report() }
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { nil }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            visibility.place(in: window)
            report()
        }

        override func viewDidHide() {
            super.viewDidHide()
            node.set(.hidden)
        }

        override func viewDidUnhide() {
            super.viewDidUnhide()
            node.set(.visible)
        }

        private func report() {
            let isShown = node.isVisible
            if shown.isShown != isShown { shown.isShown = isShown }
        }
    }
}
