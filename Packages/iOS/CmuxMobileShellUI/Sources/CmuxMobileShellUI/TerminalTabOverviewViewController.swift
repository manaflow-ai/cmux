#if os(iOS)
import CmuxMobileShellModel
import CmuxMobileSupport
import UIKit

@MainActor
final class TerminalTabOverviewViewController: UIViewController {
    private let backgroundView = UIVisualEffectView(effect: UIBlurEffect(style: .systemChromeMaterial))
    private let backgroundTint = UIView()
    private let backgroundGradient = CAGradientLayer()
    private let canvasColor = UIColor(red: 0.902, green: 0.863, blue: 0.835, alpha: 1)
    private let bottomCanvasColor = UIColor(red: 0.82, green: 0.82, blue: 0.86, alpha: 1)
    private let topBar = TerminalTabOverviewPassthroughView()
    private let searchButton = UIButton(type: .system)
    private let layoutButton = UIButton(type: .system)
    private let moreButton = UIButton(type: .system)
    private let hintCard = TerminalTabOverviewHintView()
    private let bottomBar = UIView()
    private let newTerminalButton = UIButton(type: .system)
    private let groupControl = UISegmentedControl(items: ["Private", "Tabs"])
    private let doneButton = UIButton(type: .system)

    private var workspaceName: String
    private var items: [TerminalTabOverviewItem]
    private var canCloseTabs: Bool
    private var onSelect: (MobileTerminalPreview.ID) -> Void
    private var onClose: (MobileTerminalPreview.ID) -> Void
    private var onNewTerminal: () -> Void
    private var onDone: () -> Void
    private var cards: [MobileTerminalPreview.ID: TerminalTabOverviewCardView] = [:]
    private var removedIDs = Set<MobileTerminalPreview.ID>()
    private var hasLaidOut = false
    private var isTransitioning = false
    private var hintIsVisible = true
    private var presentationBackgrounds: [(UIView, UIColor?)] = []
    private var presentationBottomBackdrop: UIView?

    init(
        workspaceName: String,
        items: [TerminalTabOverviewItem],
        canCloseTabs: Bool,
        onSelect: @escaping (MobileTerminalPreview.ID) -> Void,
        onClose: @escaping (MobileTerminalPreview.ID) -> Void,
        onNewTerminal: @escaping () -> Void,
        onDone: @escaping () -> Void
    ) {
        self.workspaceName = workspaceName
        self.items = items
        self.canCloseTabs = canCloseTabs
        self.onSelect = onSelect
        self.onClose = onClose
        self.onNewTerminal = onNewTerminal
        self.onDone = onDone
        super.init(nibName: nil, bundle: nil)
        modalPresentationCapturesStatusBarAppearance = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        // Extend the warm Safari-like canvas behind the status bar too. UIKit
        // lays the controller's view below the status bar, so leaving the root
        // background at systemBackground produces a visible white strip.
        view.backgroundColor = canvasColor
        configureBackground()
        configureTopBar()
        configureHintCard()
        configureBottomBar()
        reconcileCards(animated: false)
        UIAccessibility.post(notification: .screenChanged, argument: searchButton)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutChrome()
        if !hasLaidOut {
            hasLaidOut = true
            layoutCards(animated: false)
        }
        layoutPresentationBottomBackdrop()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // The full-screen cover's status-bar host is outside the controller's
        // safe-area bounds. Tint the window underneath it so the canvas has no
        // white seam at the top edge.
        guard let window = view.window else { return }
        window.backgroundColor = canvasColor
        presentationBackgrounds.removeAll(keepingCapacity: true)
        var ancestor = view.superview
        while let current = ancestor {
            presentationBackgrounds.append((current, current.backgroundColor))
            current.backgroundColor = canvasColor
            ancestor = current.superview
        }
        let bottomBackdrop = UIView()
        bottomBackdrop.backgroundColor = bottomCanvasColor
        bottomBackdrop.autoresizingMask = [.flexibleWidth, .flexibleTopMargin]
        window.addSubview(bottomBackdrop)
        presentationBottomBackdrop = bottomBackdrop
        layoutPresentationBottomBackdrop()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        view.window?.backgroundColor = .systemBackground
        presentationBottomBackdrop?.removeFromSuperview()
        presentationBottomBackdrop = nil
        for (view, color) in presentationBackgrounds {
            view.backgroundColor = color
        }
        presentationBackgrounds.removeAll(keepingCapacity: true)
    }

    override var prefersStatusBarHidden: Bool { false }

    override var preferredStatusBarStyle: UIStatusBarStyle {
        traitCollection.userInterfaceStyle == .dark ? .lightContent : .darkContent
    }

    private func layoutPresentationBottomBackdrop() {
        guard let window = view.window, let backdrop = presentationBottomBackdrop else { return }
        let bottomInset = max(window.safeAreaInsets.bottom, view.safeAreaInsets.bottom)
        guard bottomInset > 0 else {
            backdrop.frame = .zero
            return
        }
        backdrop.frame = CGRect(
            x: 0,
            y: window.bounds.height - bottomInset,
            width: window.bounds.width,
            height: bottomInset
        )
    }

    func update(
        workspaceName: String,
        items: [TerminalTabOverviewItem],
        canCloseTabs: Bool,
        onSelect: @escaping (MobileTerminalPreview.ID) -> Void,
        onClose: @escaping (MobileTerminalPreview.ID) -> Void,
        onNewTerminal: @escaping () -> Void,
        onDone: @escaping () -> Void
    ) {
        self.workspaceName = workspaceName
        self.items = items
        self.canCloseTabs = canCloseTabs
        self.onSelect = onSelect
        self.onClose = onClose
        self.onNewTerminal = onNewTerminal
        self.onDone = onDone
        guard isViewLoaded else { return }

        let liveIDs = Set(items.map(\.id))
        removedIDs = removedIDs.intersection(liveIDs)
        reconcileCards(animated: true)
    }

    func stopTransitions() {
        view.layer.removeAllAnimations()
        cards.values.forEach { $0.layer.removeAllAnimations() }
        isTransitioning = false
    }

    private var visibleItems: [TerminalTabOverviewItem] {
        items.filter { !removedIDs.contains($0.id) }
    }

    private func configureBackground() {
        backgroundView.translatesAutoresizingMaskIntoConstraints = true
        backgroundView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        backgroundGradient.colors = [
            UIColor(red: 0.902, green: 0.863, blue: 0.835, alpha: 0.92).cgColor,
            bottomCanvasColor.withAlphaComponent(0.92).cgColor,
        ]
        backgroundGradient.locations = [0, 1]
        backgroundGradient.startPoint = CGPoint(x: 0.1, y: 0)
        backgroundGradient.endPoint = CGPoint(x: 0.9, y: 1)
        backgroundTint.layer.addSublayer(backgroundGradient)
        backgroundTint.translatesAutoresizingMaskIntoConstraints = true
        backgroundTint.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        backgroundView.contentView.addSubview(backgroundTint)
        view.addSubview(backgroundView)
    }

    private func configureTopBar() {
        topBar.backgroundColor = .clear
        view.addSubview(topBar)

        configureCircleButton(
            searchButton,
            imageName: "magnifyingglass",
            accessibilityLabel: L10n.string("mobile.terminal.overview.search", defaultValue: "Search Tabs"),
            accessibilityIdentifier: "MobileTerminalOverviewSearch"
        )
        searchButton.addTarget(self, action: #selector(searchTapped), for: .touchUpInside)
        topBar.addSubview(searchButton)

        configureCircleButton(
            layoutButton,
            imageName: "line.3.horizontal",
            accessibilityLabel: L10n.string("mobile.terminal.overview.layout", defaultValue: "Tab Layout"),
            accessibilityIdentifier: "MobileTerminalOverviewLayout"
        )
        layoutButton.addTarget(self, action: #selector(layoutTapped), for: .touchUpInside)
        topBar.addSubview(layoutButton)

        configureCircleButton(
            moreButton,
            imageName: "ellipsis",
            accessibilityLabel: L10n.string("mobile.terminal.overview.more", defaultValue: "More Tab Options"),
            accessibilityIdentifier: "MobileTerminalOverviewMore"
        )
        moreButton.addTarget(self, action: #selector(moreTapped), for: .touchUpInside)
        topBar.addSubview(moreButton)
    }

    private func configureCircleButton(
        _ button: UIButton,
        imageName: String,
        accessibilityLabel: String,
        accessibilityIdentifier: String
    ) {
        button.translatesAutoresizingMaskIntoConstraints = true
        button.setImage(UIImage(systemName: imageName), for: .normal)
        button.setPreferredSymbolConfiguration(
            UIImage.SymbolConfiguration(pointSize: 20, weight: .regular),
            forImageIn: .normal
        )
        button.tintColor = .label
        button.backgroundColor = UIColor.secondarySystemBackground.withAlphaComponent(0.86)
        button.layer.cornerRadius = 18
        button.layer.borderColor = UIColor.separator.withAlphaComponent(0.35).cgColor
        button.layer.borderWidth = 0.7
        button.layer.shadowColor = UIColor.black.cgColor
        button.layer.shadowOpacity = 0.08
        button.layer.shadowRadius = 4
        button.layer.shadowOffset = CGSize(width: 0, height: 2)
        button.accessibilityLabel = accessibilityLabel
        button.accessibilityIdentifier = accessibilityIdentifier
        button.accessibilityTraits = .button
    }

    private func configureHintCard() {
        hintCard.translatesAutoresizingMaskIntoConstraints = true
        hintCard.onClose = { [weak self] in
            self?.setHintVisible(false, animated: true)
        }
        view.addSubview(hintCard)
    }

    private func configureBottomBar() {
        bottomBar.backgroundColor = .clear
        view.addSubview(bottomBar)

        newTerminalButton.translatesAutoresizingMaskIntoConstraints = true
        newTerminalButton.setImage(UIImage(systemName: "plus"), for: .normal)
        newTerminalButton.tintColor = .label
        newTerminalButton.backgroundColor = UIColor.secondarySystemBackground.withAlphaComponent(0.93)
        newTerminalButton.layer.cornerRadius = 24
        newTerminalButton.layer.borderColor = UIColor.separator.withAlphaComponent(0.42).cgColor
        newTerminalButton.layer.borderWidth = 0.8
        newTerminalButton.layer.shadowColor = UIColor.black.cgColor
        newTerminalButton.layer.shadowOpacity = 0.08
        newTerminalButton.layer.shadowRadius = 4
        newTerminalButton.layer.shadowOffset = CGSize(width: 0, height: 2)
        newTerminalButton.accessibilityLabel = L10n.string("mobile.terminal.new", defaultValue: "New Terminal")
        newTerminalButton.accessibilityIdentifier = "MobileTerminalOverviewNewTerminal"
        newTerminalButton.addTarget(self, action: #selector(newTerminalTapped), for: .touchUpInside)
        bottomBar.addSubview(newTerminalButton)

        groupControl.translatesAutoresizingMaskIntoConstraints = true
        groupControl.selectedSegmentIndex = 1
        groupControl.backgroundColor = UIColor.secondarySystemBackground.withAlphaComponent(0.76)
        groupControl.selectedSegmentTintColor = UIColor.systemBackground.withAlphaComponent(0.92)
        groupControl.layer.cornerRadius = 24
        groupControl.layer.borderColor = UIColor.separator.withAlphaComponent(0.45).cgColor
        groupControl.layer.borderWidth = 0.8
        groupControl.clipsToBounds = true
        groupControl.setTitleTextAttributes(
            [.foregroundColor: UIColor.secondaryLabel, .font: UIFont.systemFont(ofSize: 16, weight: .semibold)],
            for: .normal
        )
        groupControl.setTitleTextAttributes(
            [.foregroundColor: UIColor.label, .font: UIFont.systemFont(ofSize: 16, weight: .semibold)],
            for: .selected
        )
        groupControl.accessibilityIdentifier = "MobileTerminalOverviewGroupControl"
        groupControl.addTarget(self, action: #selector(groupChanged), for: .valueChanged)
        bottomBar.addSubview(groupControl)

        doneButton.translatesAutoresizingMaskIntoConstraints = true
        doneButton.setImage(UIImage(systemName: "checkmark"), for: .normal)
        doneButton.tintColor = .white
        doneButton.backgroundColor = .systemBlue
        doneButton.layer.cornerRadius = 24
        doneButton.layer.shadowColor = UIColor.black.cgColor
        doneButton.layer.shadowOpacity = 0.13
        doneButton.layer.shadowRadius = 4
        doneButton.layer.shadowOffset = CGSize(width: 0, height: 2)
        doneButton.accessibilityLabel = L10n.string("mobile.common.done", defaultValue: "Done")
        doneButton.accessibilityIdentifier = "MobileTerminalOverviewDone"
        doneButton.addTarget(self, action: #selector(doneTapped), for: .touchUpInside)
        bottomBar.addSubview(doneButton)
    }

    private func layoutChrome() {
        let bounds = view.bounds
        // Full-screen covers report a safe-area inset while their view starts
        // below the status bar. Extend the canvas upward so the status-bar
        // region uses the same gradient as the tab overview.
        let extendedBounds = CGRect(
            x: bounds.minX,
            y: bounds.minY - view.safeAreaInsets.top,
            width: bounds.width,
            height: bounds.height + view.safeAreaInsets.top + view.safeAreaInsets.bottom
        )
        backgroundView.frame = extendedBounds
        backgroundTint.frame = backgroundView.bounds
        backgroundGradient.frame = backgroundTint.bounds

        let top = view.safeAreaInsets.top + 4
        topBar.frame = CGRect(x: 16, y: top, width: max(0, bounds.width - 32), height: 48)
        searchButton.frame = CGRect(x: 4, y: 0, width: 36, height: 36)
        layoutButton.frame = CGRect(x: 59, y: 0, width: 36, height: 36)
        moreButton.frame = CGRect(x: topBar.bounds.width - 40, y: 0, width: 36, height: 36)

        // Safari raises the onboarding card when three or more tabs are shown
        // so it leaves the first row readable. With one or two tabs it drops
        // into the open space above the centered cards.
        let hintTop = visibleItems.count > 2 ? view.safeAreaInsets.top : view.safeAreaInsets.top + 39
        hintCard.frame = CGRect(x: 16, y: hintTop, width: max(0, bounds.width - 32), height: 151)
        hintCard.alpha = hintIsVisible ? 1 : 0

        let bottomY = bounds.height - view.safeAreaInsets.bottom - 48 - 4
        bottomBar.frame = CGRect(x: 0, y: bottomY, width: bounds.width, height: 48)
        newTerminalButton.frame = CGRect(x: 38, y: 0, width: 48, height: 48)
        doneButton.frame = CGRect(x: bounds.width - 86, y: 0, width: 48, height: 48)
        let groupWidth = min(171.33, max(142, bounds.width - 214))
        groupControl.frame = CGRect(x: (bounds.width - groupWidth) / 2, y: 0, width: groupWidth, height: 48)
        let groupTitle = visibleItems.count == 1 ? workspaceName : "\(visibleItems.count) Tabs"
        groupControl.setTitle(groupTitle, forSegmentAt: 1)
        view.bringSubviewToFront(topBar)
        view.bringSubviewToFront(bottomBar)
    }

    private func reconcileCards(animated: Bool) {
        let newItems = visibleItems
        let newIDs = Set(newItems.map(\.id))
        for id in cards.keys where !newIDs.contains(id) {
            cards[id]?.removeFromSuperview()
            cards[id] = nil
        }

        for item in newItems {
            if let card = cards[item.id] {
                card.update(item: item, canClose: canCloseTabs && item.canClose && newItems.count > 1)
            } else {
                let card = TerminalTabOverviewCardView(
                    item: item,
                    canClose: canCloseTabs && item.canClose && newItems.count > 1
                )
                card.onSelect = { [weak self] id in self?.select(id: id) }
                card.onClose = { [weak self] id in self?.close(id: id) }
                cards[item.id] = card
                view.addSubview(card)
            }
        }
        if hasLaidOut {
            layoutCards(animated: animated)
        }
    }

    private func layoutCards(animated: Bool) {
        let visible = visibleItems
        guard !visible.isEmpty else { return }
        let compact = visible.count > 1
        let width = compact ? floor((view.bounds.width - 48) / 2) : min(268, view.bounds.width - 32)
        let height: CGFloat = compact ? 272 : 400
        let rows = Int(ceil(Double(visible.count) / 2.0))
        let safeTop = view.safeAreaInsets.top
        let bottom = view.bounds.height - view.safeAreaInsets.bottom - 48 - 4
        let top: CGFloat
        if visible.count <= 2 {
            top = safeTop + 210
        } else {
            let desired = safeTop + 153
            let maxTop = bottom - CGFloat(rows) * height - CGFloat(max(0, rows - 1)) * 16 - 10
            top = min(desired, maxTop)
        }

        let changes = {
            for (index, item) in visible.enumerated() {
                guard let card = self.cards[item.id] else { continue }
                let column = index % 2
                let row = index / 2
                let x = compact ? 16 + CGFloat(column) * (width + 16) : (self.view.bounds.width - width) / 2
                let frame = CGRect(x: x, y: top + CGFloat(row) * (height + 16), width: width, height: height)
                card.frame = frame.integral
            }
        }
        if animated {
            UIView.animate(
                withDuration: 0.38,
                delay: 0,
                usingSpringWithDamping: 0.88,
                initialSpringVelocity: 0.2,
                options: [.beginFromCurrentState, .allowUserInteraction],
                animations: changes
            )
        } else {
            changes()
        }
    }

    private func setHintVisible(_ visible: Bool, animated: Bool) {
        hintIsVisible = visible
        let animations = { [weak self] in
            guard let self else { return }
            self.hintCard.alpha = visible ? 1 : 0
        }
        if animated {
            UIView.animate(withDuration: 0.25, animations: animations)
        } else {
            animations()
        }
    }

    private func select(id: MobileTerminalPreview.ID) {
        guard !isTransitioning, let card = cards[id] else { return }
        isTransitioning = true
        let target = view.bounds.insetBy(dx: -18, dy: -18)
        UIView.animate(
            withDuration: 0.36,
            delay: 0,
            options: [.curveEaseInOut, .beginFromCurrentState],
            animations: {
                self.cards.values.filter { $0 !== card }.forEach { $0.alpha = 0 }
                self.topBar.alpha = 0
                self.hintCard.alpha = 0
                self.bottomBar.alpha = 0
                self.backgroundTint.alpha = 0.92
                card.layer.zPosition = 10
                card.frame = target
                card.layer.cornerRadius = 0
            },
            completion: { [weak self] _ in
                guard let self else { return }
                self.onSelect(id)
                self.isTransitioning = false
            }
        )
    }

    private func close(id: MobileTerminalPreview.ID) {
        guard !isTransitioning, let card = cards[id] else { return }
        guard visibleItems.count > 1 else { return }
        removedIDs.insert(id)
        onClose(id)
        UIView.animate(
            withDuration: 0.26,
            delay: 0,
            options: [.curveEaseIn, .beginFromCurrentState],
            animations: {
                card.alpha = 0
                card.transform = CGAffineTransform(scaleX: 0.72, y: 0.72)
            },
            completion: { [weak self] _ in
                guard let self else { return }
                card.removeFromSuperview()
                self.cards[id] = nil
                self.reconcileCards(animated: true)
            }
        )
    }

    @objc private func searchTapped() {
        let alert = UIAlertController(
            title: L10n.string("mobile.terminal.overview.search", defaultValue: "Search Tabs"),
            message: L10n.string("mobile.terminal.overview.searchUnavailable", defaultValue: "Search is available when tabs have terminal output."),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: L10n.string("mobile.common.done", defaultValue: "Done"), style: .default))
        present(alert, animated: true)
    }

    @objc private func moreTapped() {
        let sheet = UIAlertController(
            title: L10n.string("mobile.terminal.overview.more", defaultValue: "More Tab Options"),
            message: workspaceName,
            preferredStyle: .actionSheet
        )
        sheet.addAction(UIAlertAction(title: L10n.string("mobile.common.done", defaultValue: "Done"), style: .cancel))
        if let popover = sheet.popoverPresentationController {
            popover.sourceView = moreButton
            popover.sourceRect = moreButton.bounds
        }
        present(sheet, animated: true)
    }

    @objc private func layoutTapped() {
        // The overview is already the grid representation. Keep the control
        // available for parity with Safari's tab-layout button and provide
        // immediate button feedback without changing the terminal ordering.
        layoutButton.alpha = 0.55
        UIView.animate(withDuration: 0.18) { [weak self] in
            self?.layoutButton.alpha = 1
        }
    }

    @objc private func newTerminalTapped() {
        guard !isTransitioning else { return }
        onNewTerminal()
    }

    @objc private func doneTapped() {
        guard !isTransitioning else { return }
        isTransitioning = true
        UIView.animate(
            withDuration: 0.25,
            delay: 0,
            options: [.curveEaseInOut, .beginFromCurrentState],
            animations: {
                self.cards.values.forEach { $0.alpha = 0 }
                self.topBar.alpha = 0
                self.hintCard.alpha = 0
                self.bottomBar.alpha = 0
                self.backgroundTint.alpha = 0.15
            },
            completion: { [weak self] _ in
                guard let self else { return }
                self.onDone()
                self.isTransitioning = false
            }
        )
    }

    @objc private func groupChanged() {
        // cmux does not expose private terminal groups yet. Keeping this state
        // local gives the control the same immediate feedback as Safari.
        groupControl.setTitle("Private", forSegmentAt: 0)
    }
}

@MainActor
private final class TerminalTabOverviewPassthroughView: UIView {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        for subview in subviews.reversed() {
            let localPoint = subview.convert(point, from: self)
            guard subview.bounds.contains(localPoint) else { continue }
            if let hit = subview.hitTest(localPoint, with: event) {
                return hit
            }
        }
        return nil
    }
}

@MainActor
private final class TerminalTabOverviewHintView: UIView {
    var onClose: (() -> Void)?

    private let handView = UIImageView(image: UIImage(systemName: "hand.tap.fill"))
    private let titleLabel = UILabel()
    private let messageLabel = UILabel()
    private let closeButton = UIButton(type: .system)

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .systemBackground
        layer.cornerRadius = 22
        layer.masksToBounds = true

        handView.tintColor = .secondaryLabel
        handView.contentMode = .scaleAspectFit
        addSubview(handView)

        titleLabel.text = L10n.string("mobile.terminal.overview.hint.title", defaultValue: "Quickly Access All Tabs")
        titleLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        titleLabel.textColor = .label
        addSubview(titleLabel)

        messageLabel.text = L10n.string(
            "mobile.terminal.overview.hint.message",
            defaultValue: "While viewing a terminal, swipe up from the tab control to quickly view all open tabs."
        )
        messageLabel.font = .systemFont(ofSize: 17, weight: .regular)
        messageLabel.textColor = .secondaryLabel
        messageLabel.numberOfLines = 3
        addSubview(messageLabel)

        closeButton.setImage(UIImage(systemName: "xmark"), for: .normal)
        closeButton.tintColor = .secondaryLabel
        closeButton.backgroundColor = .tertiarySystemFill
        closeButton.layer.cornerRadius = 15
        closeButton.accessibilityLabel = L10n.string("mobile.common.close", defaultValue: "Close")
        closeButton.accessibilityIdentifier = "MobileTerminalOverviewHintClose"
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        addSubview(closeButton)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let compact = bounds.height > 0 && frame.minY <= 70
        handView.frame = CGRect(x: 18, y: compact ? 28 : 45, width: 48, height: 48)
        closeButton.frame = CGRect(x: bounds.width - 46, y: compact ? 19 : 36, width: 30, height: 30)
        titleLabel.frame = CGRect(x: 74.67, y: compact ? 23.67 : 41, width: 239, height: compact ? 23 : 26)
        messageLabel.frame = CGRect(
            x: 74.67,
            y: compact ? 54 : 72,
            width: max(0, bounds.width - 90.67),
            height: compact ? 67.33 : 72
        )
    }

    @objc private func closeTapped() {
        onClose?()
    }
}

@MainActor
private final class TerminalTabOverviewCardView: UIControl {
    var onSelect: ((MobileTerminalPreview.ID) -> Void)?
    var onClose: ((MobileTerminalPreview.ID) -> Void)?

    private var item: TerminalTabOverviewItem
    private let surface = UIView()
    private let preview = UIView()
    private let titleLabel = UILabel()
    private let bottomTitleLabel = UILabel()
    private let groupIcon = UIImageView(image: UIImage(systemName: "square.grid.3x3.fill"))
    private let closeButton = UIButton(type: .system)
    private let lineStack = UIStackView()

    init(item: TerminalTabOverviewItem, canClose: Bool) {
        self.item = item
        super.init(frame: .zero)
        isAccessibilityElement = true
        accessibilityTraits = .button
        configure()
        update(item: item, canClose: canClose)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(item: TerminalTabOverviewItem, canClose: Bool) {
        self.item = item
        accessibilityLabel = item.title
        accessibilityIdentifier = "MobileTerminalOverviewCard-\(item.id.rawValue)"
        closeButton.isHidden = !canClose
        closeButton.accessibilityIdentifier = "MobileTerminalOverviewClose-\(item.id.rawValue)"
        titleLabel.text = item.title
        bottomTitleLabel.text = item.title
        lineStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let lines = item.previewLines.prefix(10)
        if lines.isEmpty {
            lineStack.addArrangedSubview(makeLine("No preview yet", muted: true))
        } else {
            for line in lines {
                lineStack.addArrangedSubview(makeLine(line.isEmpty ? " " : line, muted: false))
            }
        }
        setNeedsLayout()
    }

    private func configure() {
        backgroundColor = UIColor.secondarySystemBackground.withAlphaComponent(0.93)
        layer.cornerRadius = 19
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.13
        layer.shadowRadius = 12
        layer.shadowOffset = CGSize(width: 0, height: 6)
        layer.masksToBounds = false
        addTarget(self, action: #selector(selected), for: .touchUpInside)

        surface.backgroundColor = UIColor.systemBackground.withAlphaComponent(0.88)
        surface.layer.cornerRadius = 15
        surface.layer.masksToBounds = true
        // Let the card control own taps everywhere except its explicit close
        // button. Without this, UIKit hit-tests the preview container and a
        // tap on the card body never reaches UIControl.touchUpInside.
        surface.isUserInteractionEnabled = false
        addSubview(surface)

        preview.backgroundColor = UIColor(red: 0.075, green: 0.08, blue: 0.09, alpha: 1)
        preview.layer.cornerRadius = 12
        preview.layer.masksToBounds = true
        surface.addSubview(preview)

        lineStack.axis = .vertical
        lineStack.alignment = .fill
        lineStack.distribution = .fill
        lineStack.spacing = 1
        preview.addSubview(lineStack)

        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        titleLabel.textColor = .label
        titleLabel.lineBreakMode = .byTruncatingTail
        surface.addSubview(titleLabel)

        bottomTitleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        bottomTitleLabel.textColor = .label
        bottomTitleLabel.lineBreakMode = .byTruncatingTail
        surface.addSubview(bottomTitleLabel)

        groupIcon.tintColor = .secondaryLabel
        groupIcon.contentMode = .scaleAspectFit
        surface.addSubview(groupIcon)

        closeButton.setImage(UIImage(systemName: "xmark"), for: .normal)
        closeButton.tintColor = .secondaryLabel
        closeButton.backgroundColor = .tertiarySystemFill
        closeButton.layer.cornerRadius = 15
        closeButton.accessibilityLabel = L10n.string("mobile.terminal.overview.close", defaultValue: "Close Terminal")
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        addSubview(closeButton)
    }

    private func makeLine(_ text: String, muted: Bool) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        label.textColor = muted ? UIColor.white.withAlphaComponent(0.48) : UIColor.white.withAlphaComponent(0.88)
        label.lineBreakMode = .byTruncatingTail
        return label
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let inset: CGFloat = bounds.width > 220 ? 9 : 7
        surface.frame = bounds.insetBy(dx: inset, dy: inset)
        let closeSize: CGFloat = 30
        closeButton.frame = CGRect(x: surface.bounds.width - closeSize - 4, y: 4, width: closeSize, height: closeSize)
        let titleY: CGFloat = 37
        titleLabel.frame = CGRect(x: 33, y: titleY, width: max(0, surface.bounds.width - 45), height: 22)
        preview.frame = CGRect(
            x: 9,
            y: titleY + 28,
            width: max(0, surface.bounds.width - 18),
            height: max(0, surface.bounds.height - titleY - 65)
        )
        lineStack.frame = preview.bounds.insetBy(dx: 9, dy: 8)
        let bottomY = surface.bounds.height - 27
        groupIcon.frame = CGRect(x: 11, y: bottomY, width: 16, height: 16)
        bottomTitleLabel.frame = CGRect(x: 33, y: bottomY - 2, width: max(0, surface.bounds.width - 45), height: 22)
    }

    @objc private func selected() {
        onSelect?(item.id)
    }

    @objc private func closeTapped() {
        onClose?(item.id)
    }
}
#endif
