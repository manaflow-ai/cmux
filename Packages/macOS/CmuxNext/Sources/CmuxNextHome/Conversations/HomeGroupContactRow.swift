import AppKit
import CmuxHomeCore
import CmuxNextDesign

/// One person Add People offers: a check, the name and where they come from (team or contact).
/// A borderless button holding a value snapshot plus a closure (no model below the list).
final class HomeGroupContactRow: NSButton {
    let contact: HomeContact
    private let onToggle: @MainActor () -> Void

    init(contact: HomeContact, isChosen: Bool, colors: HomeGroupInfoColors, onToggle: @escaping @MainActor () -> Void) {
        self.contact = contact
        self.onToggle = onToggle
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        isBordered = false
        bezelStyle = .regularSquare
        alignment = .left
        imagePosition = .imageLeading
        imageHugsTitle = true
        image = NSImage(systemSymbolName: isChosen ? "checkmark.circle.fill" : "circle", accessibilityDescription: nil)
        contentTintColor = isChosen ? colors.litGlyph : colors.tertiary
        let source = contact.source == .team ? HomeConversationStrings.sourceTeam : HomeConversationStrings.sourceConnection
        let title = NSMutableAttributedString(string: " " + contact.name, attributes: [
            .font: isChosen ? Typography.bodyEmphasized : Typography.body, .foregroundColor: colors.primary,
        ])
        title.append(NSAttributedString(string: "  " + source, attributes: [.font: Typography.caption, .foregroundColor: colors.secondary]))
        attributedTitle = title
        target = self
        action = #selector(toggled)
        heightAnchor.constraint(equalToConstant: Metrics.sidebarRowHeight).isActive = true
        setAccessibilityLabel("\(contact.name), \(source)")
        setAccessibilityValue(isChosen ? "1" : "0")
        setAccessibilityIdentifier("cmux.home.groupInfo.add.\(contact.id.rawValue)")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func toggled() { onToggle() }
}
