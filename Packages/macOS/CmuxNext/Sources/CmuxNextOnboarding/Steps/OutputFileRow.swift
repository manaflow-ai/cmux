import AppKit
import CmuxNextDesign

/// A file the first task saved: its icon and name, then Open and Show in
/// Finder. The row's fill steps on hover (Motion's hover fade); both
/// buttons are always there, so hovering moves nothing.
final class OutputFileRow: ThemedView {
    let file: URL
    private let onOpen: (URL) -> Void
    private let onReveal: (URL) -> Void
    private var hovered = false
    private var tracking: NSTrackingArea?

    init(file: URL, onOpen: @escaping (URL) -> Void, onReveal: @escaping (URL) -> Void) {
        self.file = file
        self.onOpen = onOpen
        self.onReveal = onReveal
        super.init(frame: .zero)
        cornerRadius = 6
        fill = { [weak self] in self?.hovered == true ? Palette.hoverFill : .clear }

        let icon = NSImageView(image: NSWorkspace.shared.icon(forFile: file.path))
        icon.translatesAutoresizingMaskIntoConstraints = false
        let name = OnboardingLabel.make(file.lastPathComponent)
        name.toolTip = file.path
        let open = OnboardingControl.plainButton(OnboardingStrings.firstTaskOpen, target: nil, action: #selector(OutputFileRow.openPressed))
        let reveal = OnboardingControl.plainButton(OnboardingStrings.firstTaskReveal, target: nil, action: #selector(OutputFileRow.revealPressed))
        open.target = self
        reveal.target = self
        for view in [icon, name, open, reveal] as [NSView] { addSubview(view) }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 28),
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 18),
            icon.heightAnchor.constraint(equalToConstant: 18),
            name.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            name.centerYAnchor.constraint(equalTo: centerYAnchor),
            name.trailingAnchor.constraint(lessThanOrEqualTo: open.leadingAnchor, constant: -12),
            open.centerYAnchor.constraint(equalTo: centerYAnchor),
            reveal.leadingAnchor.constraint(equalTo: open.trailingAnchor, constant: 12),
            reveal.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            reveal.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func openPressed() { onOpen(file) }
    @objc private func revealPressed() { onReveal(file) }

    private func setHovered(_ value: Bool) {
        hovered = value
        guard let layer else { return }
        Motion.set(layer, "backgroundColor", to: (value ? Palette.hoverFill : NSColor.clear).cgColor, fade: .hover)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { setHovered(true) }
    override func mouseExited(with event: NSEvent) { setHovered(false) }
}
