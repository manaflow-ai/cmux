public import AppKit
public import CmuxAgentQuestion

extension AgentQuestionCardView {
    /// The reducer input for a key the card owns, or nil to let it fall
    /// through (every Command shortcut, unknown keys).
    static func input(for event: NSEvent) -> AgentQuestionCardState.Input? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.numericPad, .function])
        if flags == .shift, event.keyCode == 48 { return .previousItem } // Shift-Tab
        guard flags.isEmpty else { return nil }
        switch event.keyCode {
        case 126: return .up
        case 125: return .down
        case 123: return .previousItem
        case 124, 48: return .nextItem // Right, Tab
        case 36, 76: return .confirm
        case 49: return .toggle
        case 53: return .escape
        default: break
        }
        guard let characters = event.charactersIgnoringModifiers, characters.count == 1,
              let digit = Int(characters), (1...9).contains(digit) else { return nil }
        return .number(digit)
    }

    public override func keyDown(with event: NSEvent) {
        guard !event.isARepeat || [125, 126].contains(event.keyCode), let input = Self.input(for: event) else {
            return super.keyDown(with: event)
        }
        handle(input)
    }

    public override func cancelOperation(_ sender: Any?) { handle(.escape) }

    public override func mouseDown(with event: NSEvent) {
        if cardState?.question.isPending == true { window?.makeFirstResponder(self) }
        super.mouseDown(with: event)
    }
}

/// The inline Other field. Return confirms the typed answer; Escape leaves
/// the field and keeps the draft; Up and Down move back to the options.
final class AgentQuestionOtherField: NSTextField, NSTextFieldDelegate {
    weak var card: AgentQuestionCardView?

    override init(frame: NSRect) {
        super.init(frame: frame)
        isBordered = false
        drawsBackground = false
        focusRingType = .none
        usesSingleLineMode = true
        lineBreakMode = .byTruncatingHead
        delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") } // crash-allow: never decoded from a nib

    func controlTextDidChange(_ notification: Notification) {
        card?.handle(.otherText(stringValue))
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            card?.handle(.confirm)
        case #selector(NSResponder.cancelOperation(_:)):
            card?.handle(.escape)
            if let card { window?.makeFirstResponder(card) }
        case #selector(NSResponder.moveUp(_:)):
            if let card { window?.makeFirstResponder(card) }
            card?.handle(.up)
        default:
            return false
        }
        return true
    }
}
