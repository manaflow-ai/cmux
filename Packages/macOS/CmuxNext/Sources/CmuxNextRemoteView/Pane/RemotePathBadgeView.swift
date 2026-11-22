import AppKit

/// "● direct · 4 ms": the path and its live RTT, in a capsule.
final class RemotePathBadgeView: NSView {
    private let dot = CALayer()
    private let label = RemoteChrome.label("", size: 11.5, weight: .medium, mono: true)
    static let height: CGFloat = 22

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        layer?.cornerRadius = Self.height / 2
        dot.cornerRadius = 3.5
        layer?.addSublayer(dot)
        addSubview(label)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -9),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func update(status: RemoteViewStatus?, ended: Bool, colors: RemotePaneColors) {
        let text: String
        if ended {
            text = RemoteViewStrings.statusEnded
        } else if let status, status.state != .connecting {
            let path = RemoteViewStrings.path(status.path)
            text = status.rttMs.map { "\(path) · \(RemoteViewStrings.milliseconds($0))" } ?? path
        } else {
            text = RemoteViewStrings.statusConnecting
        }
        label.stringValue = text
        label.textColor = colors.textSecondary
        layer?.backgroundColor = colors.hoverFill.cgColor
        dot.backgroundColor = (ended ? colors.textTertiary : colors.dot(for: status?.path)).cgColor
        setAccessibilityLabel(text)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dot.frame = CGRect(x: 8, y: (bounds.height - 7) / 2, width: 7, height: 7)
        CATransaction.commit()
    }
}
