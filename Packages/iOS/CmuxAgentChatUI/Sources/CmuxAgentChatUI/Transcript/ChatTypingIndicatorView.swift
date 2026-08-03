import CmuxAgentChat

#if canImport(UIKit)
import UIKit

/// Native in-place agent-working indicator with a cancellable elapsed clock.
@MainActor
public final class ChatTypingIndicatorView: UIView {
    private let since: Date
    private let elapsedLabel = UILabel()
    private let dots: [UIView]
    private var clockTask: Task<Void, Never>?

    public init(agentState: ChatAgentState, incomingColor: UIColor = .secondarySystemBackground) {
        guard case .working(let since) = agentState else {
            self.since = .now
            self.dots = []
            super.init(frame: .zero)
            isHidden = true
            return
        }
        self.since = since
        self.dots = (0..<3).map { _ in
            let dot = UIView()
            dot.backgroundColor = .secondaryLabel
            dot.layer.cornerRadius = 3.5
            dot.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                dot.widthAnchor.constraint(equalToConstant: 7),
                dot.heightAnchor.constraint(equalToConstant: 7),
            ])
            return dot
        }
        super.init(frame: .zero)

        backgroundColor = incomingColor
        layer.cornerRadius = 18
        directionalLayoutMargins = .init(top: 10, leading: 14, bottom: 10, trailing: 14)

        let dotStack = UIStackView(arrangedSubviews: dots)
        dotStack.axis = .horizontal
        dotStack.alignment = .center
        dotStack.spacing = 4
        elapsedLabel.font = .monospacedDigitSystemFont(ofSize: UIFont.preferredFont(forTextStyle: .caption1).pointSize, weight: .regular)
        elapsedLabel.textColor = .secondaryLabel
        elapsedLabel.setContentHuggingPriority(.required, for: .horizontal)

        let stack = UIStackView(arrangedSubviews: [dotStack, elapsedLabel])
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: layoutMarginsGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: layoutMarginsGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: layoutMarginsGuide.bottomAnchor),
            widthAnchor.constraint(lessThanOrEqualToConstant: 200),
        ])
        isAccessibilityElement = true
        accessibilityLabel = String(
            localized: "chat.typing.accessibility",
            defaultValue: "Agent is working",
            bundle: .module
        )
        updateElapsedLabel()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            clockTask?.cancel()
            clockTask = nil
            dots.forEach { $0.layer.removeAnimation(forKey: "chat.typing.pulse") }
        } else {
            startClockIfNeeded()
            startDotAnimations()
        }
    }

    public static func elapsedLabel(seconds: Int) -> String {
        let duration = Duration.seconds(seconds)
        if seconds < 60 {
            return duration.formatted(.units(allowed: [.seconds], width: .narrow))
        }
        if seconds < 3_600 {
            return duration.formatted(.units(allowed: [.minutes, .seconds], width: .narrow))
        }
        return duration.formatted(.units(allowed: [.hours, .minutes], width: .narrow))
    }

    private func startClockIfNeeded() {
        guard clockTask == nil else { return }
        clockTask = Task { [weak self] in
            let clock = ContinuousClock()
            while !Task.isCancelled {
                guard let self else { return }
                self.updateElapsedLabel()
                do {
                    try await clock.sleep(for: .seconds(1))
                } catch {
                    return
                }
            }
        }
    }

    private func updateElapsedLabel() {
        elapsedLabel.text = Self.elapsedLabel(seconds: max(0, Int(Date.now.timeIntervalSince(since))))
    }

    private func startDotAnimations() {
        guard !UIAccessibility.isReduceMotionEnabled else { return }
        for (index, dot) in dots.enumerated() {
            let animation = CABasicAnimation(keyPath: "opacity")
            animation.fromValue = 0.3
            animation.toValue = 1
            animation.duration = 0.6
            animation.autoreverses = true
            animation.repeatCount = .infinity
            animation.beginTime = CACurrentMediaTime() + (Double(index) * 0.2)
            dot.layer.add(animation, forKey: "chat.typing.pulse")
        }
    }
}
#endif
