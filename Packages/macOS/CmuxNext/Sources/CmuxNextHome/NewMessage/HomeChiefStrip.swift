public import AppKit
import CmuxNextDesign

/// New Message's Chiefs strip (plans/cmux-next/chief-group-chats-DESIGN.md, design A): under the
/// To: field, "Chiefs" and one gray capsule per Chief not chosen yet
/// (``HomeNewMessageDraft/chiefShortcuts(contacts:limit:)``); a click adds that Chief as a token,
/// so two clicks make a group with two Chiefs. Hidden when no Chief is left to add. No animation:
/// it changes only with the tokens.
public final class HomeChiefStrip: NSView {
    /// A Chief was clicked.
    public var onChoose: (HomeContact) -> Void = { _ in }
    /// The Chiefs shown, in order.
    public private(set) var chiefs: [HomeContact] = []

    let label = ThemedLabel(labelWithString: HomeConversationStrings.composeChiefs)
    private(set) var buttons: [HomeChiefStripButton] = []

    /// The strip's height while it shows.
    public static let height: CGFloat = 34

    public override init(frame: NSRect) {
        super.init(frame: frame)
        label.font = Typography.caption
        label.ink = .secondary
        addSubview(label)
        setAccessibilityIdentifier("cmux.home.newMessage.chiefs")
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    nonisolated public override var isFlipped: Bool { true }

    /// Shows `chiefs` (hidden when empty).
    public func show(_ chiefs: [HomeContact]) {
        guard chiefs != self.chiefs else { return }
        self.chiefs = chiefs
        buttons.forEach { $0.removeFromSuperview() }
        buttons = chiefs.map { chief in
            let button = HomeChiefStripButton(name: chief.name)
            button.onPress = { [weak self] in self?.onChoose(chief) }
            addSubview(button)
            return button
        }
        isHidden = chiefs.isEmpty
        needsLayout = true
    }

    public override func layout() {
        super.layout()
        let inset: CGFloat = 14
        let size = label.intrinsicContentSize
        label.frame = NSRect(x: inset, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
        var x = label.frame.maxX + 10
        for button in buttons {
            let width = min(button.preferredWidth, max(0, bounds.width - x - inset))
            button.frame = NSRect(x: x, y: (bounds.height - HomeChiefStripButton.height) / 2, width: width, height: HomeChiefStripButton.height)
            button.isHidden = width < 40
            x += width + 6
        }
    }
}
