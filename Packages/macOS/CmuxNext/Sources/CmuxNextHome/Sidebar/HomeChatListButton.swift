import AppKit
import CmuxNextDesign

/// The Chats button at the chat's top-left, left of compose: shows or folds the conversation list
/// (`HomeSidebarSplitView.showsList`). The Chief replaces Home (the person, 2026-11-20), so the list
/// is folded by default and the Chief's chat fills the page; the person's other chats (DMs, groups,
/// other Chiefs) are one click away. The same round Liquid Glass button as compose, lit while the
/// list shows.
final class HomeChatListButton: ClickableButton {
    /// Lit, with the Hide Chats label, while the list shows.
    var isOn = false {
        didSet { if isOn != oldValue { updateLook() } }
    }

    init() {
        let side = HomeChatComposeButton.side
        super.init(frame: NSRect(x: 0, y: 0, width: side, height: side))
        title = ""
        if #available(macOS 26, *) {
            bezelStyle = .glass
            borderShape = .circle
        } else {
            bezelStyle = .circular
        }
        controlSize = .large
        imagePosition = .imageOnly
        image = NSImage(systemSymbolName: "sidebar.left", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 15, weight: .regular))
        setAccessibilityIdentifier("cmux.home.chat.chats")
        updateLook()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    private func updateLook() {
        let label = isOn ? HomeConversationStrings.hideChats : HomeConversationStrings.showChats
        setAccessibilityLabel(label)
        themedToolTip = label
        contentTintColor = isOn ? .controlAccentColor : nil
    }

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
