import AppKit

/// Native square pixel-art button used by the Sleepy Mode overlay.
@MainActor
final class SleepyPixelButton: NSButton {
    private var closure: () -> Void = {}
    private var tint = NSColor.controlAccentColor

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureBaseAppearance()
    }

    convenience init(
        title: String,
        systemImage: String,
        tint: NSColor,
        action: @escaping () -> Void
    ) {
        self.init(frame: .zero)
        configure(title: title, systemImage: systemImage, tint: tint, action: action)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        let base = super.intrinsicContentSize
        return NSSize(width: base.width + 44, height: max(48, base.height + 26))
    }

    func configure(
        title: String,
        systemImage: String,
        tint: NSColor,
        action: @escaping () -> Void
    ) {
        self.title = title
        image = NSImage(systemSymbolName: systemImage, accessibilityDescription: nil)
        imagePosition = .imageLeading
        self.tint = tint
        closure = action
        refreshAppearance(pressed: false)
        invalidateIntrinsicContentSize()
    }

    override func mouseDown(with event: NSEvent) {
        refreshAppearance(pressed: true)
        super.mouseDown(with: event)
        refreshAppearance(pressed: false)
    }

    private func configureBaseAppearance() {
        isBordered = false
        wantsLayer = true
        layer?.borderWidth = 2
        font = NSFont.monospacedSystemFont(ofSize: 16, weight: .heavy)
        contentTintColor = .white
        target = self
        action = #selector(invoke)
    }

    private func refreshAppearance(pressed: Bool) {
        layer?.backgroundColor = tint.withAlphaComponent(pressed ? 1 : 0.85).cgColor
        layer?.borderColor = NSColor.black.withAlphaComponent(0.55).cgColor
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.5
        layer?.shadowRadius = 0
        layer?.shadowOffset = CGSize(width: 0, height: pressed ? -1 : -4)
        layer?.setAffineTransform(CGAffineTransform(translationX: 0, y: pressed ? 2 : 0))
    }

    @objc private func invoke() { closure() }
}
