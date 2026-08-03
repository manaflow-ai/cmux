import CmuxAgentChat

#if canImport(UIKit)
import UIKit

/// Native compact session header with state, title, subtitle, and VoiceOver value.
@MainActor
public final class ChatSessionHeaderView: UIView {
    public enum Style: Sendable {
        case regular
        case toolbarCompact
    }

    private let indicator = ChatStateIndicatorView()
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let textStack = UIStackView()
    private let rootStack = UIStackView()
    private var descriptor: ChatSessionDescriptor
    private var agentState: ChatAgentState
    private var isConnected: Bool
    private var titleOverride: String?
    private var subtitle: String?
    private var style: Style

    public init(
        descriptor: ChatSessionDescriptor,
        agentState: ChatAgentState,
        isConnected: Bool,
        titleOverride: String? = nil,
        subtitle: String? = nil,
        style: Style = .regular
    ) {
        self.descriptor = descriptor
        self.agentState = agentState
        self.isConnected = isConnected
        self.titleOverride = titleOverride
        self.subtitle = subtitle
        self.style = style
        super.init(frame: .zero)
        installViews()
        render()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public func update(
        descriptor: ChatSessionDescriptor,
        agentState: ChatAgentState,
        isConnected: Bool,
        titleOverride: String? = nil,
        subtitle: String? = nil,
        style: Style = .regular
    ) {
        self.descriptor = descriptor
        self.agentState = agentState
        self.isConnected = isConnected
        self.titleOverride = titleOverride
        self.subtitle = subtitle
        self.style = style
        render()
    }

    private func installViews() {
        isAccessibilityElement = true
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        titleLabel.numberOfLines = 1
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        subtitleLabel.numberOfLines = 1
        subtitleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.textColor = .secondaryLabel
        subtitleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        textStack.axis = .vertical
        textStack.alignment = .leading
        textStack.spacing = 1
        textStack.addArrangedSubview(titleLabel)
        textStack.addArrangedSubview(subtitleLabel)

        rootStack.axis = .horizontal
        rootStack.alignment = .center
        rootStack.spacing = 6
        rootStack.translatesAutoresizingMaskIntoConstraints = false
        rootStack.addArrangedSubview(indicator)
        rootStack.addArrangedSubview(textStack)
        addSubview(rootStack)
        NSLayoutConstraint.activate([
            rootStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            rootStack.trailingAnchor.constraint(equalTo: trailingAnchor),
            rootStack.topAnchor.constraint(equalTo: topAnchor),
            rootStack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    private func render() {
        let title = titleOverride ?? descriptor.title ?? descriptor.agentKind.displayName
        let subtitleLine = subtitle.flatMap { $0.isEmpty ? nil : $0 }
        titleLabel.text = title
        subtitleLabel.text = subtitleLine
        subtitleLabel.isHidden = subtitleLine == nil

        switch style {
        case .regular:
            titleLabel.font = .preferredFont(forTextStyle: .headline)
            subtitleLabel.font = .preferredFont(forTextStyle: .caption2)
            directionalLayoutMargins = .zero
            indicator.size = 11
        case .toolbarCompact:
            titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
            subtitleLabel.font = .systemFont(ofSize: 11, weight: .regular)
            directionalLayoutMargins = NSDirectionalEdgeInsets(top: 0, leading: 3, bottom: 0, trailing: 3)
            rootStack.isLayoutMarginsRelativeArrangement = true
            rootStack.directionalLayoutMargins = directionalLayoutMargins
            indicator.size = 10
        }
        switch style {
        case .regular:
            rootStack.isLayoutMarginsRelativeArrangement = false
            rootStack.directionalLayoutMargins = .zero
        case .toolbarCompact:
            break
        }

        indicator.update(state: agentState, isConnected: isConnected)
        accessibilityLabel = subtitleLine.map { "\(title), \($0)" } ?? title
        accessibilityValue = stateAccessibilityValue
        invalidateIntrinsicContentSize()
    }

    private var stateAccessibilityValue: String {
        let state: String
        switch agentState {
        case .working:
            state = String(localized: "chat.header.state.working", defaultValue: "working", bundle: .module)
        case .needsInput:
            state = String(localized: "chat.header.state.needs_input", defaultValue: "needs input", bundle: .module)
        case .idle:
            state = String(localized: "chat.header.state.idle", defaultValue: "idle", bundle: .module)
        case .ended:
            state = String(localized: "chat.header.state.ended", defaultValue: "ended", bundle: .module)
        }
        guard !isConnected else { return state }
        let reconnecting = String(
            localized: "chat.header.reconnecting",
            defaultValue: "reconnecting…",
            bundle: .module
        )
        return "\(state), \(reconnecting)"
    }
}

@MainActor
private final class ChatStateIndicatorView: UIView {
    var size: CGFloat = 11 {
        didSet {
            widthConstraint.constant = size
            heightConstraint.constant = size
            layer.cornerRadius = size / 2
            setNeedsLayout()
        }
    }

    private let glyph = UIImageView()
    private lazy var widthConstraint = widthAnchor.constraint(equalToConstant: size)
    private lazy var heightConstraint = heightAnchor.constraint(equalToConstant: size)
    private var state: ChatAgentState = .idle
    private var isConnected = true

    override init(frame: CGRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        widthConstraint.isActive = true
        heightConstraint.isActive = true
        glyph.contentMode = .scaleAspectFit
        glyph.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glyph)
        NSLayoutConstraint.activate([
            glyph.leadingAnchor.constraint(equalTo: leadingAnchor),
            glyph.trailingAnchor.constraint(equalTo: trailingAnchor),
            glyph.topAnchor.constraint(equalTo: topAnchor),
            glyph.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        isAccessibilityElement = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        updateAnimation()
    }

    func update(state: ChatAgentState, isConnected: Bool) {
        self.state = state
        self.isConnected = isConnected
        layer.removeAllAnimations()
        glyph.image = nil
        layer.borderWidth = 0
        layer.borderColor = nil
        backgroundColor = .clear
        layer.cornerRadius = size / 2

        switch state {
        case .working:
            backgroundColor = .systemGreen
        case .idle:
            backgroundColor = .secondaryLabel
        case .needsInput:
            glyph.image = UIImage(systemName: "questionmark.circle.fill")?
                .withRenderingMode(.alwaysTemplate)
            glyph.tintColor = .systemOrange
        case .ended:
            layer.borderWidth = 1.3
            layer.borderColor = UIColor.secondaryLabel.cgColor
        }
        alpha = isConnected ? 1 : 0.6
        updateAnimation()
    }

    private func updateAnimation() {
        layer.removeAnimation(forKey: "chat.state.pulse")
        let isWorking: Bool
        switch state {
        case .working:
            isWorking = true
        case .idle, .needsInput, .ended:
            isWorking = false
        }
        guard window != nil,
              !UIAccessibility.isReduceMotionEnabled,
              isWorking || !isConnected else { return }
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = 1
        animation.toValue = 0.4
        animation.duration = isConnected ? 0.9 : 1.4
        animation.autoreverses = true
        animation.repeatCount = .infinity
        layer.add(animation, forKey: "chat.state.pulse")
    }
}
#endif
