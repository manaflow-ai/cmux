#if os(iOS)
import UIKit

/// Copy Mode on the phone (the Mac's Toggle Copy Mode): the page menu's Select Text… or
/// Shift-Cmd-M from a hardware keyboard. A cursor over the shell's rows, scrollback
/// included, that vi keys move (`TerminalCopyMode`); `v` selects, `y` copies, Escape
/// leaves. The touch selection draws it, so its handles still move either end, and a bar
/// above the composer has Copy and Done for touch. While it is on, keys go to it, never to
/// the terminal: an invisible view takes the keyboard focus (no software keyboard shows).
@MainActor
final class TerminalCopyModeController {
    /// The document's rows (first to one past the last) and the grid's columns.
    var documentRows: () -> Range<Int> = { 0..<0 }
    var columns: () -> Int = { 80 }
    /// A row's text, one character per cell ("" when Ghostty cannot read it).
    var rowText: (Int) -> String = { _ in "" }
    /// Where the cursor starts: the shell's cursor row, else the last row with text on screen.
    var startCursor: () -> TerminalCellPoint? = { nil }
    /// Scrolls the page so `row` shows.
    var reveal: (Int) -> Void = { _ in }
    /// Draws the selection (nil clears it).
    var draw: (_ selection: TerminalTextSelection?, _ handles: Bool) -> Void = { _, _ in }
    /// The text of the cells `from` to `to`, both inclusive.
    var text: (TerminalCellPoint, TerminalCellPoint) -> String? = { _, _ in nil }
    /// Copy Mode can start (the shell's rows, not a full-screen app).
    var isAvailable: () -> Bool = { true }
    /// Copy Mode ended; `restoreFocus`: the terminal had the keyboard when it began.
    var ended: (_ restoreFocus: Bool) -> Void = { _ in }
    /// Copy Mode started or ended (the page menu's row and the model read it).
    var activeChanged: (Bool) -> Void = { _ in }

    private(set) var mode: TerminalCopyMode?
    var isActive: Bool { mode != nil }
    private var terminalHadFocus = false
    /// The selection this controller drew last: a change that is not it came from a
    /// finger (a handle drag) or ended the selection (a tap).
    private var drawn: TerminalTextSelection?

    private let keyView = CopyModeKeyView()
    private let bar = UIView()
    private let hint = UILabel()

    func install(in view: UIView, above anchor: NSLayoutYAxisAnchor) {
        keyView.controller = self
        keyView.frame = CGRect(x: 0, y: 0, width: 1, height: 1)
        keyView.isAccessibilityElement = false
        view.addSubview(keyView)

        bar.isHidden = true
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.backgroundColor = .secondarySystemBackground
        bar.layer.cornerRadius = 20
        bar.layer.cornerCurve = .continuous
        bar.accessibilityIdentifier = "terminal.copyMode"
        bar.overrideUserInterfaceStyle = .dark
        hint.text = String(localized: "Copy Mode")
        let base = UIFont.preferredFont(forTextStyle: .subheadline)
        hint.font = UIFont(descriptor: base.fontDescriptor.withSymbolicTraits(.traitBold) ?? base.fontDescriptor, size: 0)
        hint.adjustsFontForContentSizeCategory = true
        hint.textColor = .label
        hint.accessibilityIdentifier = "terminal.copyMode.title"
        let copy = UIButton(configuration: .borderedProminent(), primaryAction: UIAction(title: String(localized: "Copy")) { @MainActor [weak self] _ in
            self?.handle(.yank)
        })
        copy.accessibilityIdentifier = "terminal.copyMode.copy"
        let done = UIButton(configuration: .bordered(), primaryAction: UIAction(title: String(localized: "Done")) { @MainActor [weak self] _ in
            self?.exit()
        })
        done.accessibilityIdentifier = "terminal.copyMode.done"
        let stack = UIStackView(arrangedSubviews: [hint, copy, done])
        stack.axis = .horizontal
        stack.spacing = 10
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(stack)
        view.addSubview(bar)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -6),
            stack.topAnchor.constraint(equalTo: bar.topAnchor, constant: 6),
            stack.bottomAnchor.constraint(equalTo: bar.bottomAnchor, constant: -6),
            bar.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            bar.bottomAnchor.constraint(equalTo: anchor, constant: -10),
        ])
    }

    /// Starts Copy Mode. `selectLine`: the touch entry (Select Text…) selects the cursor's
    /// row, so its handles show at once; the keyboard entry starts with the cursor alone.
    func enter(selectLine: Bool, terminalHadFocus: Bool) {
        guard !isActive, isAvailable() else { return }
        let rows = documentRows()
        guard !rows.isEmpty else { return }
        var cursor = startCursor() ?? TerminalCellPoint(row: rows.upperBound - 1, column: 0)
        cursor.row = min(max(cursor.row, rows.lowerBound), rows.upperBound - 1)
        var mode = TerminalCopyMode(cursor: cursor)
        if selectLine {
            let last = max(0, TerminalCopyMode.lastCharacter(in: rowText(cursor.row)))
            mode.mark = TerminalCellPoint(row: cursor.row, column: 0)
            mode.cursor = TerminalCellPoint(row: cursor.row, column: min(last, max(0, columns() - 1)))
        }
        self.terminalHadFocus = terminalHadFocus
        self.mode = mode
        bar.isHidden = false
        bar.superview?.bringSubviewToFront(bar)
        keyView.becomeFirstResponder()
        redraw()
        reveal(mode.cursor.row)
        activeChanged(true)
        UISelectionFeedbackGenerator().selectionChanged()
    }

    func toggle(terminalHadFocus: Bool) {
        if isActive { exit() } else { enter(selectLine: false, terminalHadFocus: terminalHadFocus) }
    }

    func exit() {
        guard isActive else { return }
        mode = nil
        drawn = nil
        bar.isHidden = true
        draw(nil, true)
        if keyView.isFirstResponder { keyView.resignFirstResponder() }
        activeChanged(false)
        ended(terminalHadFocus)
    }

    /// One key from the hardware keyboard or the bar.
    func handle(_ key: TerminalCopyMode.Key) {
        guard var mode else { return }
        let outcome = mode.apply(key, rows: documentRows(), columns: columns(), line: rowText)
        switch outcome {
        case .moved:
            self.mode = mode
            redraw()
            reveal(mode.cursor.row)
        case .copy(let from, let to):
            if let raw = text(from, to) {
                UIPasteboard.general.string = TerminalTextSelection.cleaned(raw)
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            }
            exit()
        case .exit:
            exit()
        }
    }

    /// The touch selection changed: a dragged handle moves the selection's ends; a tap
    /// that ended the selection ends Copy Mode.
    func selectionChanged(_ selection: TerminalTextSelection?) {
        guard isActive, selection != drawn else { return }
        guard let selection else { return exit() }
        mode = TerminalCopyMode(cursor: selection.head, mark: selection.anchor == selection.head ? nil : selection.anchor)
        drawn = selection
    }

    /// The rows moved in the document (a prune): the touch selection shifted already.
    func shiftRows(by delta: Int) {
        guard var current = mode, delta != 0 else { return }
        current.cursor.row += delta
        current.mark?.row += delta
        guard current.cursor.row >= 0 else { return exit() }
        mode = current
    }

    private func redraw() {
        guard let mode else { return }
        let selection = mode.selection
        drawn = selection
        draw(selection, mode.isVisual)
    }
}

/// Takes the hardware keyboard while Copy Mode is on: not a text input, so no software
/// keyboard shows and no key reaches the terminal.
private final class CopyModeKeyView: UIView {
    weak var controller: TerminalCopyModeController?

    override var canBecomeFirstResponder: Bool { true }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var unhandled = Set<UIPress>()
        for press in presses {
            guard let key = press.key, let controller,
                  let action = TerminalCopyMode.key(characters: key.characters,
                                                    usage: UInt16(truncatingIfNeeded: key.keyCode.rawValue)),
                  key.modifierFlags.isDisjoint(with: [.command, .control, .alternate]) else {
                unhandled.insert(press)
                continue
            }
            controller.handle(action)
        }
        if !unhandled.isEmpty { super.pressesBegan(unhandled, with: event) }
    }
}
#endif
