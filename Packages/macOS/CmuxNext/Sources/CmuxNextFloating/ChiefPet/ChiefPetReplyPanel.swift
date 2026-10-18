import AppKit
import CmuxNextDesign

/// The pet's reply box: one row with who it goes to and the text, over the pet where the bubble
/// was. It takes the keys without activating cmux (as Start Agent's panel does), so the app you
/// were in stays in front; a click elsewhere, Esc or a sent reply puts it away.
final class ChiefPetReplyPanel: NSPanel, NSTextFieldDelegate {
    static let accessibilityID = "cmux.chiefPet.reply"
    static let size = CGSize(width: 380, height: 44)

    /// Return (or ⌘Return) in the field with the chosen target and the text.
    var onSubmit: ((ChiefPetReplyTarget, String, _ command: Bool) -> Void)?
    var onClose: (() -> Void)?
    let field = ThemedTextField(frame: .zero)
    let picker = ThemedPopUpButton(frame: .zero, pullsDown: false)
    private let surface = Glass.makeOverlayPanel(cornerRadius: ChiefPetReplyPanel.size.height / 2)
    private(set) var targets: [ChiefPetReplyTarget] = []

    init() {
        super.init(contentRect: NSRect(origin: .zero, size: Self.size),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        ThemeScope.app.adopt(self)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isFloatingPanel = true
        level = .floating
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        setAccessibilityIdentifier(Self.accessibilityID)
        surface.translatesAutoresizingMaskIntoConstraints = true
        surface.frame = NSRect(origin: .zero, size: Self.size)
        surface.autoresizingMask = [.width, .height]
        contentView = surface
        picker.controlSize = .small
        picker.isBordered = false
        picker.setAccessibilityLabel(ChiefPetStrings.replyTarget)
        picker.target = self
        picker.action = #selector(pick)
        field.isBordered = false
        field.drawsBackground = false
        field.fill = { .clear }
        field.font = Typography.body
        field.lineBreakMode = .byTruncatingTail
        field.cell?.usesSingleLineMode = true
        field.delegate = self
        surface.contentView.addSubview(picker)
        surface.contentView.addSubview(field)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    var target: ChiefPetReplyTarget? {
        targets.indices.contains(picker.indexOfSelectedItem) ? targets[picker.indexOfSelectedItem] : nil
    }

    /// Lists `targets`, keeping the chosen one when it is still there, else the first.
    func show(targets: [ChiefPetReplyTarget]) {
        let kept = target
        self.targets = targets
        picker.removeAllItems()
        picker.addItems(withTitles: targets.map(ChiefPetReply.title))
        if let kept, let index = targets.firstIndex(of: kept) { picker.selectItem(at: index) } else { picker.selectItem(at: 0) }
        pick()
    }

    @objc private func pick() {
        field.placeholderString = target.map(ChiefPetReply.placeholder)
        layoutRow()
    }

    private func layoutRow() {
        picker.sizeToFit()
        let height = Self.size.height
        let side: CGFloat = 14
        let width = min(picker.frame.width, 140)
        picker.frame = CGRect(x: side, y: ((height - picker.frame.height) / 2).rounded(), width: width, height: picker.frame.height)
        let fieldHeight = ceil(field.intrinsicContentSize.height)
        let x = picker.frame.maxX + 6
        field.frame = CGRect(x: x, y: ((height - fieldHeight) / 2).rounded(), width: Self.size.width - x - side - 4, height: fieldHeight)
    }

    /// Takes the keys (never activating cmux) with the caret in the field.
    func present() {
        orderFrontRegardless()
        makeKey()
        makeFirstResponder(field)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            guard let target else { return true }
            let command = NSApp.currentEvent?.modifierFlags.contains(.command) ?? false
            onSubmit?(target, field.stringValue, command)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            onClose?()
            return true
        default:
            return false
        }
    }

    override func cancelOperation(_ sender: Any?) {
        onClose?()
    }

    override func resignKey() {
        super.resignKey()
        // A click in another app or window puts it away; the typed text stays for the next open.
        onClose?()
    }
}
