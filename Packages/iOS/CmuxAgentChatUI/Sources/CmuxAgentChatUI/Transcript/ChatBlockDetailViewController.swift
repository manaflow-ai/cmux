#if os(iOS)
import CMUXMobileCore
import CmuxMobileToast
import UIKit

/// Native detail sheet for transcript cards and code blocks.
@MainActor
final class ChatBlockDetailViewController: UIViewController {
    private let detail: ChatBlockDetail
    private let artifactLoader: ChatArtifactLoader
    private let toasts: ToastCenter
    private let onOpenTerminal: (@MainActor () -> Void)?

    init(
        detail: ChatBlockDetail,
        artifactLoader: ChatArtifactLoader,
        toastCenter: ToastCenter,
        onOpenTerminal: (@MainActor () -> Void)? = nil
    ) {
        self.detail = detail
        self.artifactLoader = artifactLoader
        self.toasts = toastCenter
        self.onOpenTerminal = onOpenTerminal
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        view.accessibilityIdentifier = "ChatBlockDetailSheet"
        title = detail.title
        navigationItem.largeTitleDisplayMode = .never
        configureToolbar()
        configureContent()
    }

    private func configureToolbar() {
        let done = UIBarButtonItem(
            title: String(
                localized: "chat.detail.done",
                defaultValue: "Done",
                bundle: .module
            ),
            style: .done,
            target: self,
            action: #selector(donePressed)
        )
        done.accessibilityIdentifier = "ChatBlockDetailDoneButton"
        navigationItem.leftBarButtonItem = done

        let copy = UIBarButtonItem(
            title: String(
                localized: "chat.detail.copy_all",
                defaultValue: "Copy All",
                bundle: .module
            ),
            style: .plain,
            target: self,
            action: #selector(copyAll)
        )
        copy.accessibilityIdentifier = "ChatBlockDetailCopyAllButton"
        copy.isEnabled = !detail.copyText.isEmpty
        if onOpenTerminal != nil {
            let terminal = UIBarButtonItem(
                image: UIImage(systemName: "terminal"),
                style: .plain,
                target: self,
                action: #selector(openTerminal)
            )
            terminal.accessibilityLabel = String(
                localized: "chat.terminal.open_in_terminal",
                defaultValue: "Open in terminal",
                bundle: .module
            )
            terminal.accessibilityIdentifier = "ChatBlockDetailOpenTerminalButton"
            navigationItem.rightBarButtonItems = [copy, terminal]
        } else {
            navigationItem.rightBarButtonItem = copy
        }
    }

    private func configureContent() {
        let scrollView = UIScrollView()
        scrollView.alwaysBounceVertical = true
        scrollView.keyboardDismissMode = .interactive
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)

        let stack = UIStackView()
        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(stack)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -16),
            stack.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor, constant: -32),
        ])

        if let subtitle = detail.subtitle, !subtitle.isEmpty {
            let label = UILabel()
            label.text = subtitle
            label.font = .preferredFont(forTextStyle: .footnote)
            label.textColor = .secondaryLabel
            label.numberOfLines = 0
            label.adjustsFontForContentSizeCategory = true
            stack.addArrangedSubview(label)
        }
        for section in detail.sections {
            stack.addArrangedSubview(sectionView(section))
        }
        if artifactLoader.supportsArtifacts {
            let paths = deduplicatedArtifactPaths()
            if !paths.isEmpty {
                stack.addArrangedSubview(artifactActionsView(paths: paths))
            }
        }
    }

    private func sectionView(_ section: ChatBlockDetailSection) -> UIView {
        let stack = UIStackView()
        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = 8

        let title = UILabel()
        title.text = section.title
        title.font = .preferredFont(forTextStyle: .caption1).withTraits(.traitBold)
        title.textColor = .secondaryLabel
        title.adjustsFontForContentSizeCategory = true
        stack.addArrangedSubview(title)

        let content = UITextView()
        content.text = section.text.isEmpty ? " " : section.text
        content.isEditable = false
        content.isSelectable = true
        content.backgroundColor = section.style == .monospaced
            ? .quaternarySystemFill
            : .clear
        content.textColor = .label
        content.adjustsFontForContentSizeCategory = true
        content.textContainerInset = section.style == .monospaced
            ? UIEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
            : .zero
        content.textContainer.lineFragmentPadding = 0
        switch section.style {
        case .prose:
            content.font = .preferredFont(forTextStyle: .body)
            content.isScrollEnabled = false
        case .monospaced:
            let font = UIFont.monospacedSystemFont(ofSize: 12, weight: .regular)
            content.font = font
            content.isScrollEnabled = true
            content.showsHorizontalScrollIndicator = true
            content.showsVerticalScrollIndicator = false
            content.alwaysBounceHorizontal = true
            content.textContainer.widthTracksTextView = false
            content.textContainer.size = CGSize(
                width: CGFloat.greatestFiniteMagnitude,
                height: CGFloat.greatestFiniteMagnitude
            )
            let lineCount = max(1, content.text.split(separator: "\n", omittingEmptySubsequences: false).count)
            content.heightAnchor.constraint(
                equalToConstant: ceil(CGFloat(lineCount) * font.lineHeight + 20)
            ).isActive = true
            content.layer.cornerRadius = 8
            content.layer.cornerCurve = .continuous
        }
        stack.addArrangedSubview(content)
        return stack
    }

    private func artifactActionsView(paths: [String]) -> UIView {
        let stack = UIStackView()
        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = 8

        let title = UILabel()
        title.text = String(
            localized: "chat.artifact.actions.title",
            defaultValue: "Referenced Items",
            bundle: .module
        )
        title.font = .preferredFont(forTextStyle: .caption1).withTraits(.traitBold)
        title.textColor = .secondaryLabel
        stack.addArrangedSubview(title)
        for path in paths {
            stack.addArrangedSubview(artifactActionView(path: path))
        }
        return stack
    }

    private func artifactActionView(path: String) -> UIView {
        let button = UIButton(type: .system)
        button.contentHorizontalAlignment = .fill
        button.accessibilityLabel = String(
            localized: "chat.artifact.open_item",
            defaultValue: "Open item",
            bundle: .module
        )
        button.accessibilityValue = path
        button.addAction(UIAction { [weak self] _ in
            self?.openArtifact(path: path)
        }, for: .primaryActionTriggered)

        let labels = UIStackView()
        labels.axis = .vertical
        labels.alignment = .leading
        labels.spacing = 2
        labels.isUserInteractionEnabled = false
        let name = UILabel()
        name.text = URL(fileURLWithPath: path).lastPathComponent
        name.font = .preferredFont(forTextStyle: .footnote).withTraits(.traitBold)
        name.lineBreakMode = .byTruncatingMiddle
        let fullPath = UILabel()
        fullPath.text = path
        fullPath.font = .monospacedSystemFont(ofSize: UIFont.preferredFont(forTextStyle: .caption2).pointSize, weight: .regular)
        fullPath.textColor = .secondaryLabel
        fullPath.lineBreakMode = .byTruncatingMiddle
        labels.addArrangedSubview(name)
        labels.addArrangedSubview(fullPath)

        let icon = UIImageView(image: UIImage(systemName: "doc.text.magnifyingglass"))
        icon.tintColor = .tintColor
        icon.setContentHuggingPriority(.required, for: .horizontal)
        let row = UIStackView(arrangedSubviews: [labels, icon])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 8
        row.isLayoutMarginsRelativeArrangement = true
        row.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 10, leading: 10, bottom: 10, trailing: 10)
        row.isUserInteractionEnabled = false
        row.translatesAutoresizingMaskIntoConstraints = false
        button.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: button.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: button.trailingAnchor),
            row.topAnchor.constraint(equalTo: button.topAnchor),
            row.bottomAnchor.constraint(equalTo: button.bottomAnchor),
        ])
        button.backgroundColor = .quaternarySystemFill
        button.layer.cornerRadius = 8
        button.layer.cornerCurve = .continuous
        return button
    }

    private func deduplicatedArtifactPaths() -> [String] {
        var seen: Set<String> = []
        return detail.artifactPaths.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    private func openArtifact(path: String) {
        let viewer = ChatArtifactViewerController(
            path: path,
            loader: artifactLoader,
            toastCenter: toasts,
            onDone: { [weak self] in self?.dismiss(animated: true) }
        )
        navigationController?.pushViewController(viewer, animated: true)
    }

    @objc private func donePressed() {
        dismiss(animated: true)
    }

    @objc private func copyAll() {
        guard !detail.copyText.isEmpty else { return }
        UIPasteboard.general.string = detail.copyText
        if toasts.isEnabled {
            toasts.present(.copied())
        } else {
            MobileHapticFeedback().notification(.success)
        }
    }

    @objc private func openTerminal() {
        guard let onOpenTerminal else { return }
        dismiss(animated: true, completion: onOpenTerminal)
    }
}

private extension UIFont {
    func withTraits(_ traits: UIFontDescriptor.SymbolicTraits) -> UIFont {
        guard let descriptor = fontDescriptor.withSymbolicTraits(traits) else { return self }
        return UIFont(descriptor: descriptor, size: pointSize)
    }
}
#endif
