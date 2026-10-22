import AppKit
import CmuxNextDesign

// The group editor as a menu (Lawrence 2026-10-21, u9795: "mousedown on the 3 dots, mousemove,
// then mouseup to select what i want"): one highlight that the pointer, a press drag from the
// more button and the arrow keys all move; a release or Return runs it; typing renames.
extension SidebarGroupEditorPanel {
    /// The rows and dots a press or the keys can choose, in reading order.
    private var choices: [NSView] { swatches + [customSwatch, emojiButton] + rows }

    /// What sits under `point` (screen coordinates): a row or a dot, nil elsewhere.
    func choice(at point: CGPoint) -> NSView? {
        guard isPresented else { return nil }
        let local = convertPoint(fromScreen: point)
        return choices.first { view in
            view.window === self && !view.isHiddenOrHasHiddenAncestor && view.convert(view.bounds, to: nil).contains(local)
        }
    }

    /// Moves the one highlight to `view` (a row or a palette dot), or clears it.
    func highlight(_ view: NSView?) {
        highlighted = view
        for row in rows { row.isHighlighted = row === view }
        for swatch in swatches { swatch.isHighlighted = swatch === view }
    }

    /// The pointer entered or left a row or dot.
    func hover(_ view: NSView?, inside: Bool) {
        guard let view else { return }
        if inside { highlight(view) } else if highlighted === view { highlight(nil) }
    }

    /// Runs `view`: a row's action (the editor closes), a dot's color (it stays open), the
    /// custom color or the icon picker.
    func choose(_ view: NSView) {
        switch view {
        case let row as SidebarGroupEditorRow: row.onPress?()
        case let swatch as SidebarGroupSwatchView: pick(swatch.color)
        case let custom as GroupCustomSwatchView: custom.onPress?()
        case let button as SidebarIconButton: button.onPress?()
        default: break
        }
    }

    // MARK: PopupPressTracking

    func pressMoved(to point: CGPoint) {
        guard isPresented else { return }
        let target = choice(at: point)
        if target !== highlighted { highlight(target) }
    }

    func pressReleased(at point: CGPoint) {
        guard isPresented else { return }
        guard let target = choice(at: point) else { return highlight(nil) }
        choose(target)
    }

    // MARK: Keys

    /// The keys while the panel itself has them (opened as a menu): Up and Down walk the rows,
    /// Left and Right the color dots, Return runs the highlight, Escape closes with the name
    /// unchanged, Tab or a typed character moves into the name (the character replaces it).
    override func keyDown(with event: NSEvent) {
        if handleMenuKey(event) { return }
        super.keyDown(with: event)
    }

    /// Handles one key of the menu; false leaves it to AppKit.
    func handleMenuKey(_ event: NSEvent) -> Bool {
        guard isPresented else { return false }
        let modifiers = event.modifierFlags.intersection([.command, .control, .option])
        switch event.specialKey {
        case .downArrow?: step(rows, by: 1)
        case .upArrow?: step(rows, by: -1)
        case .rightArrow?: step(swatches, by: 1)
        case .leftArrow?: step(swatches, by: -1)
        case .carriageReturn?, .enter?, .newline?:
            if let highlighted { choose(highlighted) } else { dismiss() }
        case .tab?:
            focusName()
        default:
            if event.keyCode == 53 { // Escape
                cancel()
                return true
            }
            guard modifiers.isEmpty, let text = event.characters, !text.isEmpty,
                  text.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else { return false }
            focusName()
            nameField.currentEditor()?.insertText(text)
        }
        return true
    }

    /// Moves the highlight `delta` places within `group`, wrapping; from outside the group it
    /// starts at the group's first (down, right) or last (up, left) member.
    private func step(_ group: [NSView], by delta: Int) {
        guard !group.isEmpty else { return }
        let next: Int
        if let current = group.firstIndex(where: { $0 === highlighted }) {
            next = (current + delta + group.count) % group.count
        } else {
            next = delta > 0 ? 0 : group.count - 1
        }
        highlight(group[next])
    }
}
