public import AppKit
import CmuxNextDesign

/// The "vim" pill in the terminal's top-right corner while copy mode is on
/// (the old app's copy-mode indicator). Clicks go to the terminal below.
final class TerminalCopyModeBadge: NSVisualEffectView {
    static var text: String {
        String(localized: "terminal.copyMode.indicator", defaultValue: "vim", bundle: .module)
    }

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.masksToBounds = true
        layer?.borderWidth = Metrics.lineWidth(1)
        layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor

        let icon = NSImageView(image: NSImage(systemSymbolName: "keyboard.badge.ellipsis", accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = .secondaryLabelColor
        let label = NSTextField(labelWithString: Self.text)
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.textColor = .labelColor
        for view in [icon, label] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(Self.text)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
