import AppKit
import CCmuxMotionFFI
import CmuxNextDesign
import CmuxNextWakeups

/// Selecting text while a program has the mouse (design/terminal.md, "Selecting text while a program
/// has the mouse"): Option-drag goes to Ghostty as its Shift override, and the first plain drag a
/// program takes in this terminal shows a hint once. The rule and its state are cmux-motion's
/// (`terminal_selection`, over the app FFI); this keeps the state, converts the event's keys, shows the
/// hint on the shared modifier-hint glass chip and hides it after ``visibleFor``.
@MainActor
final class TerminalSelectionHint {
    static let visibleFor: Duration = .seconds(4)
    static let bottomInset: CGFloat = 12

    static var text: String {
        ModuleResourceBundle.terminal.text("terminal.selectionHint", defaultValue: "Option or Shift + drag selects text")
    }

    weak var view: NSView?
    private var state = CmuxTerminalSelection()
    private var chip: ShortcutHintChipView?
    /// The chip's size for ``text``, measured once, at the first drag that may show it.
    private lazy var chipSize: NSSize = {
        let chip = ShortcutHintChipView()
        chip.text = Self.text
        return chip.fittingSize
    }()
    private let hideTimer: DemandTimer

    /// - Parameter clock: The hide deadline's clock; tests pass a manual clock.
    init(view: NSView?, clock: any Clock<Duration> = ContinuousClock()) {
        self.view = view
        hideTimer = DemandTimer(owner: "TerminalSelectionHint.hide", clock: clock)
    }

    /// Whether the left press held now goes as an Option selection.
    var selecting: Bool { state.selection_press }

    /// Whether a left press with `flags` needs to know if the program has the mouse (the terminal's lock).
    func pressAsksCapture(_ flags: NSEvent.ModifierFlags) -> Bool {
        cmux_terminal_selection_press_asks_capture(&state, Self.keys(flags))
    }

    /// A left press with `flags`; `captured`: the program has the mouse.
    func pressed(_ flags: NSEvent.ModifierFlags, captured: Bool) {
        _ = cmux_terminal_selection_press(&state, Self.keys(flags), captured)
    }

    /// `flags` as Ghostty gets them with a press, drag or release of an Option selection.
    func following(_ flags: NSEvent.ModifierFlags) -> NSEvent.ModifierFlags {
        Self.flags(cmux_terminal_selection_following(&state, Self.keys(flags)), keeping: flags)
    }

    /// A drag of the left press; the first one after a plain press the program took shows the hint,
    /// in a terminal wide enough for it. A narrower one never clips it: a later drag shows it.
    func dragged() {
        guard state.hint_armed, let view, chipSize.width + Self.bottomInset * 2 <= view.bounds.width,
              cmux_terminal_selection_dragged(&state) else { return }
        show(in: view)
    }

    /// The left button's release, after its keys went out.
    func released() {
        cmux_terminal_selection_released(&state)
    }

    private func show(in view: NSView) {
        let chip = ShortcutHintChipView()
        chip.text = Self.text
        chip.alphaValue = 0
        let size = chipSize
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

    // MARK: Keys

    /// The keys the rule reads, as its bits (cmux-motion `terminal_selection::KEY_*`), in bit order.
    private static let keyBits: [NSEvent.ModifierFlags] = [.command, .shift, .option, .control, .function]

    static func keys(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        keyBits.enumerated().reduce(0) { bits, key in flags.contains(key.element) ? bits | (1 << UInt32(key.offset)) : bits }
    }

    /// The left and right device-dependent bits of each key that has them (IOKit's NX_DEVICE*KEYMASK),
    /// which `GhosttyInput.mods` reads as the right-side keys.
    private static let sideBits: [(NSEvent.ModifierFlags, UInt)] = [
        (.shift, UInt(NX_DEVICELSHIFTKEYMASK | NX_DEVICERSHIFTKEYMASK)),
        (.control, UInt(NX_DEVICELCTLKEYMASK | NX_DEVICERCTLKEYMASK)),
        (.option, UInt(NX_DEVICELALTKEYMASK | NX_DEVICERALTKEYMASK)),
        (.command, UInt(NX_DEVICELCMDKEYMASK | NX_DEVICERCMDKEYMASK)),
    ]

    /// `keys` as flags, with `flags`' other bits (Caps Lock, the numeric pad) kept. A key that goes
    /// loses its side bits too, so a right Option let go does not reach Ghostty as Alt-Right.
    static func flags(_ keys: UInt32, keeping flags: NSEvent.ModifierFlags) -> NSEvent.ModifierFlags {
        let result = keyBits.enumerated().reduce(flags.subtracting(NSEvent.ModifierFlags(keyBits))) { result, key in
            keys & (1 << UInt32(key.offset)) != 0 ? result.union(key.element) : result
        }
        let gone = sideBits.reduce(UInt(0)) { mask, side in result.contains(side.0) ? mask : mask | side.1 }
        return NSEvent.ModifierFlags(rawValue: result.rawValue & ~gone)
    }
}
