import AppKit
import CmuxNextDesign

/// The Chats button at the chat's top-left, left of compose: shows or folds the conversation list
/// (`HomeSidebarSplitView.showsList`). The Chief replaces Home (the person, 2026-11-20), so the list
/// is folded by default and the Chief's chat fills the page; the person's other chats (DMs, groups,
/// other Chiefs) are one click away. The same flat top-row button as compose, lit while the
/// list shows.
final class HomeChatListButton: ClickableButton {
    /// Lit, with the Hide Chats label, while the list shows.
    var isOn = false {
        didSet { if isOn != oldValue { updateLook() } }
    }

    init() {
        let side = HomeChatComposeButton.side
        super.init(frame: NSRect(x: 0, y: 0, width: side, height: side))
        HomeChatTopRowLook.apply(to: self, symbol: "sidebar.left")
        setAccessibilityIdentifier("cmux.home.chat.chats")
        updateLook()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    private func updateLook() {
        let label = isOn ? HomeConversationStrings.hideChats : HomeConversationStrings.showChats
        setAccessibilityLabel(label)
        themedToolTip = label
        HomeChatTopRowLook.applyInk(to: self, lit: isOn)
    }

    override func layout() {
        super.layout()
        HomeChatTopRowLook.layout(self)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        HomeChatTopRowLook.applyInk(to: self, lit: isOn)
    }

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
