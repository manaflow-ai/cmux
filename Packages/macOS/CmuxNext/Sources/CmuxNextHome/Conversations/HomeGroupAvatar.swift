import AppKit
import CmuxNextDesign

/// A member's monogram disc in the group info sheet (an agent shows a sparkle instead of letters).
final class HomeGroupAvatar: NSView {
    private static let side: CGFloat = 24

    init(initials: String, isAgent: Bool, colors: HomeGroupInfoColors) {
        super.init(frame: NSRect(x: 0, y: 0, width: Self.side, height: Self.side))
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = Self.side / 2
        layer?.backgroundColor = colors.hover.cgColor
        setAccessibilityElement(false)
        let mark: NSView
        if isAgent {
            let config = NSImage.SymbolConfiguration(pointSize: TypeScale.caption, weight: .regular)
            let image = NSImageView(image: NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)?.withSymbolConfiguration(config) ?? NSImage())
            image.contentTintColor = colors.secondary
            mark = image
        } else {
            let label = NSTextField(labelWithString: initials)
            label.font = Typography.system(size: TypeScale.caption, weight: TypeScale.emphasis)
            label.textColor = colors.secondary
            label.alignment = .center
            mark = label
        }
        mark.translatesAutoresizingMaskIntoConstraints = false
        addSubview(mark)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.side),
            heightAnchor.constraint(equalToConstant: Self.side),
            mark.centerXAnchor.constraint(equalTo: centerXAnchor),
            mark.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
