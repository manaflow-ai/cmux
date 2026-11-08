import AppKit
import CmuxNextDesign
import CmuxNextWakeups

/// The hint that Option- or Shift-drag selects text while a program has the mouse
/// (design/terminal.md, "Selecting text while a program has the mouse"). The first plain drag a
/// program takes in this terminal shows it once, on the shared modifier-hint glass chip; it fades out
/// after ``visibleFor``.
@MainActor
final class TerminalSelectionHint {
    static let visibleFor: Duration = .seconds(4)
    static let bottomInset: CGFloat = 12

    static var text: String {
        ModuleResourceBundle.terminal.text("terminal.selectionHint", defaultValue: "Option or Shift + drag selects text")
    }

    weak var view: TerminalSurfaceView?
    /// Whether this terminal has shown the hint.
    private(set) var shown = false
    /// A plain left press went to the program: its first drag shows the hint.
    private var armed = false
    private var chip: ShortcutHintChipView?
    private let hideTimer: DemandTimer

    /// - Parameter clock: The hide deadline's clock; tests pass a manual clock.
    init(view: TerminalSurfaceView, clock: any Clock<Duration> = ContinuousClock()) {
        self.view = view
        hideTimer = DemandTimer(owner: "TerminalSelectionHint.hide", clock: clock)
    }

    /// A left press with `flags`. Only until the hint has shown, a press with no keys held checks
    /// whether the program has the mouse (the terminal's lock).
    func pressed(_ flags: NSEvent.ModifierFlags) {
        armed = !shown && flags.isDisjoint(with: [.command, .shift, .control, .option, .function]) && view?.programCapturesMouse == true
    }

    /// A drag of the left press; the first one after an armed press shows the hint.
    func dragged() {
        guard armed, let view else { return }
        armed = false
        shown = true
        let chip = ShortcutHintChipView()
        chip.text = Self.text
        chip.alphaValue = 0
        let size = chip.fittingSize
        chip.frame = NSRect(x: ((view.bounds.width - size.width) / 2).rounded(), y: Self.bottomInset, width: size.width, height: size.height)
        chip.autoresizingMask = [.minXMargin, .maxXMargin, .maxYMargin]
        view.addSubview(chip)
        self.chip = chip
        Motion.overlays.animate(.fadeIn, in: chip) { chip.animator().alphaValue = 1 }
        hideTimer.schedule(after: Self.visibleFor) { @MainActor [weak self] in self?.hide() }
    }

    func hide() {
        hideTimer.cancel()
        guard let chip else { return }
        self.chip = nil
        Motion.overlays.animate(.fadeOut, in: chip, { chip.animator().alphaValue = 0 }, completion: {
            chip.removeFromSuperview()
        })
    }

    /// The hint on screen (tests, diagnostics).
    var shownText: String? { chip?.text }
}
