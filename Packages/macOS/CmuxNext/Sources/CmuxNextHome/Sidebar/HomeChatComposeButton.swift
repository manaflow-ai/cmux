import AppKit
import CmuxNextDesign

/// The chat's compose button while the Home list shows avatars only: Messages' round Liquid Glass
/// button at the chat's top-left, beside the traffic lights (refs/imessage-layout/2.png). It runs
/// the list's own New Message action and right-click menu (`HomeSidebarView.newMessage`).
final class HomeChatComposeButton: ClickableButton {
    /// The button's diameter: the list's glass filter circle's (`HomeSidebarHeaderLayout.side`),
    /// as Messages' compose and filter circles are one size.
    static let side: CGFloat = HomeSidebarHeaderLayout.side
    /// A right-click menu (the list compose's: New Chief, Invite).
    var contextMenu: (() -> NSMenu?)?

    init(label: String) {
        super.init(frame: NSRect(x: 0, y: 0, width: Self.side, height: Self.side))
        title = ""
        if #available(macOS 26, *) {
            bezelStyle = .glass
            borderShape = .circle
        } else {
            bezelStyle = .circular
        }
        controlSize = .large
        imagePosition = .imageOnly
        image = NSImage(systemSymbolName: "square.and.pencil", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 15, weight: .regular))
        setAccessibilityLabel(label)
        setAccessibilityIdentifier("cmux.home.chat.compose")
        themedToolTip = label
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func menu(for event: NSEvent) -> NSMenu? { contextMenu?() ?? super.menu(for: event) }
}
