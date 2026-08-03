import AppKit
import CmuxFoundation

@MainActor
final class SimulatorFeatureDisabledNativeView: NSView {
    private var backgroundColor: NSColor

    init(backgroundColor: NSColor) {
        self.backgroundColor = backgroundColor
        super.init(frame: .zero)
        wantsLayer = true
        let icon = NSImageView(image: NSImage(systemSymbolName: "iphone.slash", accessibilityDescription: nil) ?? NSImage())
        icon.imageScaling = .scaleProportionallyDown
        icon.contentTintColor = .secondaryLabelColor
        let title = NSTextField(labelWithString: String(
            localized: "simulator.featureDisabled.title",
            defaultValue: "Simulator is temporarily unavailable"
        ))
        title.font = GlobalFontMagnification.systemFont(ofSize: 13, weight: .semibold)
        let message = NSTextField(wrappingLabelWithString: String(
            localized: "simulator.featureDisabled.message",
            defaultValue: "This feature has been disabled remotely."
        ))
        message.font = GlobalFontMagnification.systemFont(ofSize: 13)
        message.textColor = .secondaryLabelColor
        message.alignment = .center
        let stack = NSStackView(views: [icon, title, message])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 40),
            icon.heightAnchor.constraint(equalToConstant: 40),
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -24),
        ])
        update(backgroundColor: backgroundColor)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(backgroundColor: NSColor) {
        self.backgroundColor = backgroundColor
        layer?.backgroundColor = backgroundColor.cgColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        layer?.backgroundColor = backgroundColor.cgColor
    }
}
