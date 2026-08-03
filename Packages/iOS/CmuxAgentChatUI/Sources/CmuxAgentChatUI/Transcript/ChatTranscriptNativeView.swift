#if os(iOS)
import UIKit

/// Fully native transcript surface, including table ownership and its floating bottom affordance.
@MainActor
final class ChatTranscriptNativeView: UIView {
    let tableView = ChatTranscriptUITableView(frame: .zero, style: .plain)
    var onScrollButtonFrameChanged: @MainActor (CGRect) -> Void = { _ in }

    private let scrollToBottomButton = UIButton(type: .system)
    private var scrollButtonBottomConstraint: NSLayoutConstraint?
    private var configuration: ChatTranscriptTableConfiguration?
    private var scrollToBottomRequest = 0
    private var isAtBottom = true
    private lazy var coordinator = ChatTranscriptTableView.Coordinator(
        onAtBottomChanged: { [weak self] in self?.setAtBottom($0) }
    )

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear

        tableView.backgroundColor = .clear
        tableView.separatorStyle = .none
        tableView.keyboardDismissMode = .interactive
        if #available(iOS 26.0, *) {
            tableView.contentInsetAdjustmentBehavior = .automatic
        } else {
            tableView.contentInsetAdjustmentBehavior = .never
        }
        tableView.estimatedRowHeight = 96
        tableView.rowHeight = UITableView.automaticDimension
        tableView.allowsSelection = false
        tableView.accessibilityIdentifier = "ChatTranscriptTableView"
        tableView.register(
            ChatTranscriptCell.self,
            forCellReuseIdentifier: ChatTranscriptCell.reuseIdentifier
        )
        tableView.applyScrollEdgeEffects(topSoft: true, bottomSoft: true)
        tableView.dataSource = coordinator
        tableView.delegate = coordinator
        coordinator.attach(tableView)
        tableView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(tableView)

        var buttonConfiguration = UIButton.Configuration.filled()
        buttonConfiguration.image = UIImage(systemName: "arrow.down")
        buttonConfiguration.baseForegroundColor = .white
        buttonConfiguration.baseBackgroundColor = .systemBlue
        buttonConfiguration.cornerStyle = .capsule
        scrollToBottomButton.configuration = buttonConfiguration
        scrollToBottomButton.accessibilityIdentifier = "ChatScrollToBottom"
        scrollToBottomButton.accessibilityLabel = String(
            localized: "chat.scroll_to_bottom.accessibility",
            defaultValue: "Scroll to latest message",
            bundle: .module
        )
        scrollToBottomButton.addTarget(
            self,
            action: #selector(scrollToBottom),
            for: .primaryActionTriggered
        )
        scrollToBottomButton.isHidden = true
        scrollToBottomButton.alpha = 0
        scrollToBottomButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollToBottomButton)

        let bottom = scrollToBottomButton.bottomAnchor.constraint(
            equalTo: bottomAnchor,
            constant: -8
        )
        scrollButtonBottomConstraint = bottom
        NSLayoutConstraint.activate([
            tableView.leadingAnchor.constraint(equalTo: leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: trailingAnchor),
            tableView.topAnchor.constraint(equalTo: topAnchor),
            tableView.bottomAnchor.constraint(equalTo: bottomAnchor),
            scrollToBottomButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            bottom,
            scrollToBottomButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 40),
            scrollToBottomButton.heightAnchor.constraint(equalToConstant: 40),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(configuration: ChatTranscriptTableConfiguration) {
        self.configuration = configuration
        coordinator.update(
            configuration: configuration,
            in: tableView,
            scrollToBottomRequest: scrollToBottomRequest
        )
    }

    func setComposerOverlayBottomInset(_ inset: CGFloat) {
        let constant = -(max(0, ceil(inset)) + 8)
        guard scrollButtonBottomConstraint?.constant != constant else { return }
        scrollButtonBottomConstraint?.constant = constant
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard !scrollToBottomButton.isHidden, let window else {
            onScrollButtonFrameChanged(.zero)
            return
        }
        onScrollButtonFrameChanged(
            scrollToBottomButton.convert(
                scrollToBottomButton.bounds.insetBy(dx: -3, dy: -3),
                to: window
            )
        )
    }

    private func setAtBottom(_ value: Bool) {
        guard isAtBottom != value else { return }
        isAtBottom = value
        let shouldShow = !value
        if shouldShow { scrollToBottomButton.isHidden = false }
        UIView.animate(
            withDuration: UIAccessibility.isReduceMotionEnabled ? 0 : 0.2,
            animations: {
                self.scrollToBottomButton.alpha = shouldShow ? 1 : 0
                self.scrollToBottomButton.transform = shouldShow
                    ? .identity
                    : CGAffineTransform(scaleX: 0.8, y: 0.8)
            },
            completion: { _ in
                self.scrollToBottomButton.isHidden = !shouldShow
                self.setNeedsLayout()
            }
        )
    }

    @objc private func scrollToBottom() {
        guard let configuration else { return }
        scrollToBottomRequest &+= 1
        coordinator.update(
            configuration: configuration,
            in: tableView,
            scrollToBottomRequest: scrollToBottomRequest
        )
    }
}
#endif
