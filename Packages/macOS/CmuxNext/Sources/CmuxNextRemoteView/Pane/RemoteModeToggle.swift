import AppKit

/// The View / Control toggle: two segments, the selected one on a gray
/// fill (never an accent color). Control can be disabled (while the path
/// is too slow, the banner offers "Control Anyway" instead).
final class RemoteModeToggle: NSView {
    var onSelect: ((RemoteControlMode) -> Void)?
    private let viewButton = RemoteChromeButton(title: RemoteViewStrings.modeView, height: 22)
    private let controlButton = RemoteChromeButton(title: RemoteViewStrings.modeControl, height: 22)

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        layer?.cornerRadius = 13
        let row = RemoteChrome.row([viewButton, controlButton], spacing: 2, insets: NSEdgeInsets(top: 2, left: 2, bottom: 2, right: 2))
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        viewButton.onPress = { [weak self] in self?.onSelect?(.view) }
        controlButton.onPress = { [weak self] in self?.onSelect?(.control) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func update(selected: RemoteControlMode, colors: RemotePaneColors) {
        layer?.backgroundColor = colors.hoverFill.cgColor
        for (button, mode) in [(viewButton, RemoteControlMode.view), (controlButton, .control)] {
            let isSelected = mode == selected
            button.apply(
                text: isSelected ? colors.textPrimary : colors.textSecondary, hover: colors.hoverFill,
                fill: isSelected ? colors.selectionFill : .clear)
            button.setAccessibilityValue(isSelected)
        }
    }
}
