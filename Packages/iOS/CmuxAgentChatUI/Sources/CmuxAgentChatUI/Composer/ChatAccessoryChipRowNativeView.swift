#if os(iOS)
import CmuxAgentChat
import UIKit

/// Native horizontal shortcut strip for the mobile composer.
@MainActor
final class ChatAccessoryChipRowNativeView: UIView {
    private static let trailingFadeWidth: CGFloat = 34
    private let rootStack = UIStackView()
    private let leadingStack = UIStackView()
    private let scrollView = UIScrollView()
    private let scrollStack = UIStackView()
    private let fadeMask = CAGradientLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        rootStack.axis = .horizontal
        rootStack.alignment = .center
        rootStack.spacing = 10
        rootStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(rootStack)

        leadingStack.axis = .horizontal
        leadingStack.alignment = .center
        leadingStack.spacing = 6
        rootStack.addArrangedSubview(leadingStack)

        scrollView.showsHorizontalScrollIndicator = false
        scrollView.alwaysBounceHorizontal = false
        scrollView.isDirectionalLockEnabled = true
        scrollStack.axis = .horizontal
        scrollStack.alignment = .center
        scrollStack.spacing = 6
        scrollStack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(scrollStack)
        NSLayoutConstraint.activate([
            scrollStack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            scrollStack.trailingAnchor.constraint(
                equalTo: scrollView.contentLayoutGuide.trailingAnchor,
                constant: -Self.trailingFadeWidth
            ),
            scrollStack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            scrollStack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            scrollStack.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor),
        ])
        rootStack.addArrangedSubview(scrollView)

        NSLayoutConstraint.activate([
            rootStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            rootStack.trailingAnchor.constraint(equalTo: trailingAnchor),
            rootStack.topAnchor.constraint(equalTo: topAnchor),
            rootStack.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: 32),
        ])
        leadingStack.setContentCompressionResistancePriority(.required, for: .horizontal)
        scrollView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(
        agentState: ChatAgentState,
        leadingShortcuts: [ChatAccessoryShortcut],
        shortcuts: [ChatAccessoryShortcut],
        onInterrupt: @escaping @MainActor (Bool) -> Void,
        onOpenTerminal: @escaping @MainActor () -> Void
    ) {
        clear(leadingStack)
        clear(scrollStack)
        let usesHostShortcuts = !leadingShortcuts.isEmpty || !shortcuts.isEmpty
        let isWorking: Bool = if case .working = agentState { true } else { false }
        let stop = ChatAccessoryShortcut(
            id: "chat.chip.stop",
            title: String(
                localized: "chat.chip.stop",
                defaultValue: "Stop",
                bundle: .module
            ),
            tint: .red,
            action: { onInterrupt(false) }
        )

        var resolvedLeading = usesHostShortcuts ? leadingShortcuts : []
        var resolvedScrollable: [ChatAccessoryShortcut]
        if usesHostShortcuts {
            resolvedScrollable = shortcuts
        } else {
            resolvedScrollable = [
                ChatAccessoryShortcut(
                    id: "chat.chip.esc",
                    title: String(
                        localized: "chat.chip.esc",
                        defaultValue: "Esc",
                        bundle: .module
                    ),
                    action: { onInterrupt(false) }
                ),
                ChatAccessoryShortcut(
                    id: "chat.chip.ctrl_c",
                    title: String(
                        localized: "chat.chip.ctrl_c",
                        defaultValue: "Ctrl-C",
                        bundle: .module
                    ),
                    action: { onInterrupt(true) }
                ),
                ChatAccessoryShortcut(
                    id: "chat.chip.terminal",
                    title: String(
                        localized: "chat.chip.terminal",
                        defaultValue: "Terminal",
                        bundle: .module
                    ),
                    action: onOpenTerminal
                ),
            ]
        }
        if isWorking {
            if usesHostShortcuts {
                resolvedLeading.insert(stop, at: 0)
            } else {
                resolvedScrollable.insert(stop, at: 0)
            }
        }
        for shortcut in resolvedLeading {
            leadingStack.addArrangedSubview(button(for: shortcut))
        }
        for shortcut in resolvedScrollable {
            scrollStack.addArrangedSubview(button(for: shortcut))
        }
        leadingStack.isHidden = resolvedLeading.isEmpty
        scrollView.isHidden = resolvedScrollable.isEmpty
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let needsFade = scrollView.contentSize.width > scrollView.bounds.width + 1
        guard needsFade else {
            scrollView.layer.mask = nil
            return
        }
        fadeMask.frame = scrollView.bounds
        fadeMask.colors = [UIColor.black.cgColor, UIColor.black.cgColor, UIColor.clear.cgColor]
        let fadeStart = max(0, 1 - (Self.trailingFadeWidth / max(scrollView.bounds.width, 1)))
        fadeMask.locations = [0, NSNumber(value: Double(fadeStart)), 1]
        fadeMask.startPoint = CGPoint(x: 0, y: 0.5)
        fadeMask.endPoint = CGPoint(x: 1, y: 0.5)
        scrollView.layer.mask = fadeMask
    }

    private func button(for shortcut: ChatAccessoryShortcut) -> UIButton {
        let button = UIButton(type: .system)
        var configuration: UIButton.Configuration
        if #available(iOS 26.0, *) {
            configuration = .glass()
        } else {
            configuration = .gray()
        }
        configuration.cornerStyle = .capsule
        configuration.contentInsets = NSDirectionalEdgeInsets(
            top: 4,
            leading: shortcut.systemImage == nil ? 12 : 8,
            bottom: 4,
            trailing: shortcut.systemImage == nil ? 12 : 8
        )
        if let systemImage = shortcut.systemImage {
            configuration.image = UIImage(systemName: systemImage)
        } else {
            configuration.title = shortcut.title
        }
        configuration.baseForegroundColor = switch shortcut.tint {
        case .red: .systemRed
        case .secondary: .secondaryLabel
        case nil: .label
        }
        button.configuration = configuration
        button.accessibilityIdentifier = shortcut.id
        button.accessibilityLabel = shortcut.accessibilityLabel ?? shortcut.title
        button.addAction(UIAction { _ in shortcut.perform() }, for: .primaryActionTriggered)
        return button
    }

    private func clear(_ stack: UIStackView) {
        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
    }
}
#endif
