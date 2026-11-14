import AppKit
import CmuxNextDesign

/// The pet's reply box: one capsule of the notices' size and glass with who it goes to and the
/// text, just over the pet in the notices' place. Talking to the mini's own chat (Show in Mini), it
/// also shows that chat's newest reply under the field: two lines, unfolded by a click on them. It takes the keys without activating cmux (as Start Agent's panel does), so the app you
/// were in stays in front; a click elsewhere, Esc or a sent reply puts it away.
final class ChiefPetReplyPanel: NSPanel, NSTextFieldDelegate {
    static let accessibilityID = "cmux.chiefPet.reply"
    static let size = CGSize(width: ChiefPetBubblePanel.width, height: ChiefPetBubblePanel.pillHeight)
    /// Closer to the pet than the notices: it is what the click on the pet opened.
    static let gap: CGFloat = 12

    /// In the notices' place by the pet: toward the quadrant with room (`ChiefPetBubblePanel.frame`).
    static func frame(over pet: CGRect, in visible: CGRect, height: CGFloat = size.height) -> CGRect {
        ChiefPetBubblePanel.frame(height: height, over: pet, in: visible, width: size.width, gap: gap)
    }

    /// The newest reply's lines while folded, and unfolded at most.
    static let foldedLines = 2
    static let unfoldedLines = 12
    /// The reply's inset from the box's sides and bottom, and its gap under the field's row.
    static let side: CGFloat = 22
    static let bottom: CGFloat = 14

    /// Return (or ⌘Return) in the field with the chosen target and the text.
    var onSubmit: ((ChiefPetReplyTarget, String, _ command: Bool) -> Void)?
    var onClose: (() -> Void)?
    /// The box's height changed (a reply shown, gone, unfolded): the controller places it again.
    var onResize: (() -> Void)?
    let field = ThemedTextField(frame: .zero)
    let picker = ThemedPopUpButton(frame: .zero, pullsDown: false)
    private let surface: NSView = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        ? Glass.makeOverlayPanel(cornerRadius: ChiefPetReplyPanel.size.height / 2)
        : Glass.makePanel(style: .regular, cornerRadius: ChiefPetReplyPanel.size.height / 2, interactive: true)
    private(set) var targets: [ChiefPetReplyTarget] = []
    /// The newest reply of the mini's chat (``ChiefPetHome/latest``), and the target it belongs to.
    private(set) var latest: (target: ChiefPetReplyTarget, text: String)?
    /// The reply unfolded past its two lines (a click on it).
    private(set) var unfolded = false
    let latestLabel = ChromeLabel(wrappingLabelWithString: "")

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
        // Not hidden with cmux (⌘H, Hide Others): Message the Chief from Any App orders it in without unhiding the app.
        canHide = false
        // Agent output and replies stay out of screen shares and recordings.
        sharingType = .none
        becomesKeyOnlyIfNeeded = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        setAccessibilityIdentifier(Self.accessibilityID)
        surface.translatesAutoresizingMaskIntoConstraints = true
        surface.frame = NSRect(origin: .zero, size: Self.size)
        surface.autoresizingMask = [.width, .height]
        // The glass is the background; the controls sit in a plain container over it.
        let container = NSView(frame: NSRect(origin: .zero, size: Self.size))
        container.addSubview(surface)
        contentView = container
        picker.controlSize = .small
        picker.isBordered = false
        picker.setAccessibilityLabel(ChiefPetStrings.replyTarget)
        picker.target = self
        picker.action = #selector(pick)
        field.isBordered = false
        field.drawsBackground = false
        field.fill = { .clear }
        field.font = .systemFont(ofSize: TypeScale.title)
        field.lineBreakMode = .byTruncatingTail
        field.maximumNumberOfLines = 1
        field.delegate = self
        latestLabel.font = .systemFont(ofSize: TypeScale.body)
        // Wrapped, the last line that fits ends in an ellipsis: unfolded, more lines show.
        latestLabel.wraps = true
        latestLabel.truncatesLastVisibleLine = true
        latestLabel.maximumNumberOfLines = Self.foldedLines
        latestLabel.isSelectable = false
        latestLabel.isHidden = true
        latestLabel.setAccessibilityRole(.button)
        container.addSubview(picker)
        container.addSubview(field)
        container.addSubview(latestLabel)
        container.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(clicked(_:))))
    }

    /// A click on the reply unfolds it to ``unfoldedLines``, and folds it again.
    @objc private func clicked(_ recognizer: NSClickGestureRecognizer) {
        guard !latestLabel.isHidden, latestLabel.frame.contains(recognizer.location(in: recognizer.view)) else { return }
        unfolded.toggle()
        layoutRow()
    }

    /// The height the box needs: the field's row, and the shown reply under it.
    var preferredHeight: CGFloat {
        guard !latestLabel.isHidden else { return Self.size.height }
        return Self.size.height + latestHeight + Self.bottom
    }

    private var latestHeight: CGFloat {
        let width = Self.size.width - Self.side * 2
        return ceil(latestLabel.size(forWidth: width).height)
    }

    /// The newest reply of the mini's chat `target` (nil: none, or the Chief's box without one). It
    /// shows while that target is chosen; a new reply folds back to two lines.
    func show(latest text: String?, of target: ChiefPetReplyTarget) {
        let next = text.map { (target, $0.trimmingCharacters(in: .whitespacesAndNewlines)) }.flatMap { $0.1.isEmpty ? nil : $0 }
        guard next?.0 != latest?.target || next?.1 != latest?.text else { return }
        if next?.1 != latest?.text { unfolded = false }
        latest = next.map { (target: $0.0, text: $0.1) }
        layoutRow()
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    var target: ChiefPetReplyTarget? {
        targets.indices.contains(picker.indexOfSelectedItem) ? targets[picker.indexOfSelectedItem] : nil
    }

    /// Lists `targets`. The chosen one stays chosen while its tab is listed (a newer notice of the same
    /// tab included); when it leaves, the box falls back to the Chief, never to another session, and
    /// drops the typed text (written for that session, it must not go to the Chief). A first list
    /// starts on its first target.
    func show(targets: [ChiefPetReplyTarget]) {
        let kept = target
        self.targets = targets
        picker.removeAllItems()
        // Menu items, not addItems(withTitles:): two notices with the same title must stay two items.
        for title in targets.map(ChiefPetReply.title) {
            picker.menu?.addItem(NSMenuItem(title: title, action: nil, keyEquivalent: ""))
        }
        if let kept {
            let stayed = targets.firstIndex { ChiefPetReply.sameTarget($0, kept) }
            if stayed == nil { field.stringValue = "" }
            // The fallback is the mini's own chat, the last target (the Chief by default).
            picker.selectItem(at: stayed ?? max(targets.count - 1, 0))
        } else {
            picker.selectItem(at: 0)
        }
        pick()
    }

    @objc private func pick() {
        field.placeholderString = target.map(ChiefPetReply.placeholder)
        layoutRow()
    }

    private func layoutRow() {
        let oldHeight = preferredHeight
        // The reply shows under its own chat only: another target chosen hides it.
        let reply = latest.flatMap { latest in target.map { ChiefPetReply.sameTarget($0, latest.target) } == true ? latest.text : nil }
        latestLabel.isHidden = reply == nil
        latestLabel.stringValue = reply ?? ""
        latestLabel.textColor = Palette.textSecondary
        latestLabel.maximumNumberOfLines = unfolded ? Self.unfoldedLines : Self.foldedLines
        latestLabel.setAccessibilityLabel(reply)
        latestLabel.setAccessibilityHelp(unfolded ? ChiefPetStrings.showLess : ChiefPetStrings.showMore)
        let total = preferredHeight
        let rowY = total - Self.size.height
        picker.sizeToFit()
        let height = Self.size.height
        let side = Self.side
        let width = min(picker.frame.width, 140)
        picker.frame = CGRect(x: side, y: rowY + ((height - picker.frame.height) / 2).rounded(), width: width, height: picker.frame.height)
        let fieldHeight = ceil(field.intrinsicContentSize.height)
        let x = picker.frame.maxX + 6
        field.frame = CGRect(x: x, y: rowY + ((height - fieldHeight) / 2).rounded(), width: Self.size.width - x - side - 4, height: fieldHeight)
        if !latestLabel.isHidden {
            latestLabel.frame = CGRect(x: side, y: Self.bottom, width: Self.size.width - side * 2, height: latestHeight)
        }
        if total != oldHeight || frame.height != total { onResize?() }
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

    /// ⌘Return opens the target. The field gets every other key first; of the rest, editing keys go on
    /// to the Edit menu and other command keys stop here, since the main menu would act on the cmux
    /// window behind (Close Tab, New Tab, Quit), as Start Agent's panel does.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return super.performKeyEquivalent(with: event) }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function])
        if flags == .command, event.keyCode == 36 || event.keyCode == 76 {
            if let target { onSubmit?(target, field.stringValue, true) }
            return true
        }
        if super.performKeyEquivalent(with: event) { return true }
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        let editing = (flags == .command && ["a", "c", "v", "x", "z"].contains(key)) || (flags == [.command, .shift] && ["v", "z"].contains(key))
        return flags.contains(.command) && !editing
    }

    override func resignKey() {
        super.resignKey()
        // A click in another app or window puts it away; the typed text stays for the next open.
        onClose?()
    }
}
