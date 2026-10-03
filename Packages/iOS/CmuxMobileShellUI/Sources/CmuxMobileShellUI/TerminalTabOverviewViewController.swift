#if os(iOS)
import CmuxMobileShellModel
import CmuxMobileSupport
import UIKit

private extension UIButton {
    func configureLiquidGlass(
        imageName: String? = nil,
        title: String? = nil,
        prominent: Bool,
        symbolPointSize: CGFloat = 22,
        foregroundColor: UIColor? = nil
    ) {
        let image = imageName.flatMap { UIImage(systemName: $0) }
        if #available(iOS 26.0, *) {
            var configuration = prominent
                ? UIButton.Configuration.prominentGlass()
                : UIButton.Configuration.glass()
            configuration.image = image
            configuration.title = title
            configuration.baseForegroundColor = foregroundColor ?? (prominent ? .white : .label)
            configuration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(
                pointSize: symbolPointSize,
                weight: .regular
            )
            configuration.contentInsets = .zero
            configuration.cornerStyle = .capsule
            self.configuration = configuration
        } else {
            setImage(image, for: .normal)
            setTitle(title, for: .normal)
            setPreferredSymbolConfiguration(
                UIImage.SymbolConfiguration(pointSize: symbolPointSize, weight: .regular),
                forImageIn: .normal
            )
            tintColor = foregroundColor ?? (prominent ? .white : .label)
            setTitleColor(foregroundColor ?? (prominent ? .white : .label), for: .normal)
        }
    }
}

private extension UIVisualEffectView {
    func configureLiquidGlass(fallback: UIBlurEffect.Style = .systemMaterial) {
        if #available(iOS 26.0, *) {
            let glass = UIGlassEffect(style: .regular)
            glass.isInteractive = true
            effect = glass
        } else {
            effect = UIBlurEffect(style: fallback)
        }
        // The system effect owns the surface color. A second content fill makes
        // the material opaque and produces a different result from Safari.
        contentView.backgroundColor = .clear
    }
}

@MainActor
final class TerminalTabOverviewViewController: UIViewController {
    private let backgroundView = UIVisualEffectView(effect: nil)
    private let backgroundTint = UIView()
    private let backgroundGradient = CAGradientLayer()
    // These are the two endpoints of Safari's warm-to-cool tab overview
    // canvas. Keeping the color in the canvas, rather than painting a panel
    // behind each control, lets the system glass material pick up the same
    // background as the reference UI.
    private let canvasColor = UIColor(red: 0.918, green: 0.855, blue: 0.808, alpha: 1)
    private let bottomCanvasColor = UIColor(red: 0.824, green: 0.831, blue: 0.863, alpha: 1)
    private let privateLockColor = UIColor(red: 0.095, green: 0.095, blue: 0.095, alpha: 1)
    private let topBar = TerminalTabOverviewPassthroughView()
    private let searchButton = UIButton(type: .system)
    private let layoutButton = UIButton(type: .system)
    private let moreButton = UIButton(type: .system)
    private let hintCard = TerminalTabOverviewHintView()
    private let privateBrowsingView = TerminalTabOverviewPrivateView()
    private let privateLockView = TerminalTabOverviewPrivateLockView()
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
    private var isPrivateMode = false
    private var manualOrderIDs: [MobileTerminalPreview.ID]?
    private var searchOverlay: TerminalTabOverviewSearchOverlay?
    private var draggingID: MobileTerminalPreview.ID?
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
        configurePrivateBrowsingView()
        configurePrivateLockView()
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
        if let manualOrderIDs, Set(manualOrderIDs) == Set(items.map(\.id)) {
            let incomingByID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
            self.items = manualOrderIDs.compactMap { incomingByID[$0] }
        } else {
            self.manualOrderIDs = nil
            self.items = items
        }
        self.canCloseTabs = canCloseTabs
        self.onSelect = onSelect
        self.onClose = onClose
        self.onNewTerminal = onNewTerminal
        self.onDone = onDone
        guard isViewLoaded else { return }

        let liveIDs = Set(items.map(\.id))
        removedIDs = removedIDs.intersection(liveIDs)
        reconcileCards(animated: true)
        if isPrivateMode {
            privateBrowsingView.setNeedsLayout()
        }
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
        backgroundGradient.colors = [canvasColor.cgColor, bottomCanvasColor.cgColor]
        backgroundGradient.locations = [0, 0.87]
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
            imageName: "line.3.horizontal.decrease",
            accessibilityLabel: L10n.string("mobile.terminal.overview.layout", defaultValue: "Tab Layout"),
            accessibilityIdentifier: "MobileTerminalOverviewLayout"
        )
        layoutButton.menu = UIMenu(children: [
            UIMenu(
                title: "Organize Tabs",
                image: UIImage(systemName: "rectangle.stack"),
                children: [UIAction(title: "Never") { _ in }]
            ),
        ])
        layoutButton.showsMenuAsPrimaryAction = true
        topBar.addSubview(layoutButton)

        configureCircleButton(
            moreButton,
            imageName: "ellipsis",
            accessibilityLabel: L10n.string("mobile.terminal.overview.more", defaultValue: "More Tab Options"),
            accessibilityIdentifier: "MobileTerminalOverviewMore"
        )
        // Safari presents these two actions through UIKit's menu presenter.
        // Using UIButton.menu keeps the Liquid Glass surface, focus behavior,
        // dismissal animation, and VoiceOver hierarchy in UIKit's ownership.
        let arrangeTabsMenu = UIMenu(
            title: "Arrange Tabs By",
            image: UIImage(systemName: "arrow.up.arrow.down"),
            children: [
                UIAction(title: "Title") { _ in },
                UIAction(title: "Website") { _ in },
            ]
        )
        moreButton.menu = UIMenu(children: [
            UIAction(
                title: "Manage Tab Groups",
                image: UIImage(systemName: "list.bullet")
            ) { _ in },
            UIAction(
                title: "Select Tabs",
                image: UIImage(systemName: "checkmark.circle")
            ) { _ in },
            arrangeTabsMenu,
        ])
        moreButton.showsMenuAsPrimaryAction = true
        topBar.addSubview(moreButton)
    }

    private func configureCircleButton(
        _ button: UIButton,
        imageName: String,
        accessibilityLabel: String,
        accessibilityIdentifier: String
    ) {
        button.translatesAutoresizingMaskIntoConstraints = true
        button.configureLiquidGlass(imageName: imageName, prominent: false)
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

    private func configurePrivateBrowsingView() {
        privateBrowsingView.translatesAutoresizingMaskIntoConstraints = true
        privateBrowsingView.isHidden = true
        view.addSubview(privateBrowsingView)
    }

    private func configurePrivateLockView() {
        privateLockView.translatesAutoresizingMaskIntoConstraints = true
        privateLockView.isHidden = true
        privateLockView.onDismiss = { [weak self] in
            self?.dismissPrivateLock(animated: true)
        }
        view.addSubview(privateLockView)
    }

    private func configureBottomBar() {
        bottomBar.backgroundColor = .clear
        view.addSubview(bottomBar)

        newTerminalButton.translatesAutoresizingMaskIntoConstraints = true
        newTerminalButton.configureLiquidGlass(imageName: "plus", prominent: false)
        newTerminalButton.accessibilityLabel = L10n.string("mobile.terminal.new", defaultValue: "New Terminal")
        newTerminalButton.accessibilityIdentifier = "MobileTerminalOverviewNewTerminal"
        newTerminalButton.addTarget(self, action: #selector(newTerminalTapped), for: .touchUpInside)
        bottomBar.addSubview(newTerminalButton)

        groupControl.translatesAutoresizingMaskIntoConstraints = true
        groupControl.selectedSegmentIndex = 1
        // iOS 26 supplies the segmented control's Liquid Glass treatment.
        // Keep the control unpainted so UIKit owns the material and selection
        // transition instead of layering a second hand-built pill on top.
        groupControl.backgroundColor = .clear
        groupControl.selectedSegmentTintColor = nil
        groupControl.clipsToBounds = false
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
        doneButton.configureLiquidGlass(imageName: "checkmark", prominent: true)
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

        let top = view.safeAreaInsets.top
        topBar.frame = CGRect(x: 0, y: top, width: bounds.width, height: 48)
        searchButton.frame = CGRect(x: 16, y: 0, width: 48, height: 48)
        layoutButton.frame = CGRect(x: 72, y: 0, width: 48, height: 48)
        moreButton.frame = CGRect(x: bounds.width - 64, y: 0, width: 48, height: 48)

        // Safari raises the onboarding card when three or more tabs are shown
        // so it leaves the first row readable. With one or two tabs it moves
        // below the top controls and leaves the centered cards below it.
        let hintTop = visibleItems.count > 2 ? view.safeAreaInsets.top : view.safeAreaInsets.top + 63
        // Safari's teaching card is just over 135 points tall on the iPhone
        // reference device. The card keeps a small breathing space before the
        // first row instead of touching the tab previews.
        hintCard.frame = CGRect(x: 16, y: hintTop, width: max(0, bounds.width - 32), height: 137)
        hintCard.alpha = isPrivateMode ? 0 : (hintIsVisible ? 1 : 0)

        privateBrowsingView.frame = CGRect(
            x: 16,
            y: view.safeAreaInsets.top + 80,
            width: max(0, bounds.width - 32),
            height: max(0, bounds.height - view.safeAreaInsets.top - view.safeAreaInsets.bottom - 160)
        )
        if !isTransitioning {
            privateBrowsingView.isHidden = !isPrivateMode
        }
        // Safari presents the locked-private explanation as a bottom sheet. It
        // leaves the status bar and the top controls in the warm canvas while
        // the sheet owns the lower edge and its safe-area backdrop.
        let privateLockTop = view.safeAreaInsets.top + 24
        privateLockView.frame = CGRect(
            x: 0,
            y: privateLockTop,
            width: bounds.width,
            height: max(0, bounds.maxY - privateLockTop)
        )
        privateLockView.isHidden = !isPrivateMode || privateLockView.isHidden

        let bottomY = bounds.height - view.safeAreaInsets.bottom - 48 - 4
        bottomBar.frame = CGRect(x: 0, y: bottomY, width: bounds.width, height: 48)
        newTerminalButton.frame = CGRect(x: 38, y: 0, width: 48, height: 48)
        doneButton.frame = CGRect(x: bounds.width - 86, y: 0, width: 48, height: 48)
        let groupWidth = min(171.33, max(142, bounds.width - 214))
        groupControl.frame = CGRect(x: (bounds.width - groupWidth) / 2, y: 0, width: groupWidth, height: 48)
        let groupTitle = visibleItems.count == 1 ? workspaceName : "\(visibleItems.count) Tabs"
        groupControl.setTitle(groupTitle, forSegmentAt: 1)
        layoutButton.isHidden = isPrivateMode
        // Keep the teaching card in the hierarchy before the top chrome. Safari
        // renders the glass controls above the card when their bounds overlap;
        // the card's passthrough hit-test still lets those controls receive
        // taps while exposing its close affordance where it is unobstructed.
        if hintIsVisible && !isPrivateMode {
            view.bringSubviewToFront(hintCard)
        }
        view.bringSubviewToFront(topBar)
        view.bringSubviewToFront(bottomBar)
        if isPrivateMode {
            view.bringSubviewToFront(privateBrowsingView)
            if !privateLockView.isHidden {
                view.bringSubviewToFront(privateLockView)
            }
        }
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
                card.onDrag = { [weak self] id, state, location in
                    self?.dragChanged(id: id, state: state, location: location)
                }
                cards[item.id] = card
                view.addSubview(card)
            }
        }
        if hasLaidOut {
            layoutCards(animated: animated)
        }
        cards.values.forEach { $0.isHidden = isPrivateMode }
    }

    private func layoutCards(animated: Bool) {
        let visible = visibleItems
        guard !isPrivateMode else { return }
        guard !visible.isEmpty else { return }
        let compact = visible.count > 1
        let width = compact ? floor((view.bounds.width - 48) / 2) : min(268, view.bounds.width - 32)
        let height: CGFloat = compact ? 272 : 400
        let rows = Int(ceil(Double(visible.count) / 2.0))
        let safeTop = view.safeAreaInsets.top
        let bottom = view.bounds.height - view.safeAreaInsets.bottom - 48 - 4
        let top: CGFloat
        if compact {
            // With the teaching card visible, Safari places the first row
            // directly below it. Once the card is dismissed the grid rises
            // into the space below the top controls.
            let desired: CGFloat
            if hintIsVisible {
                desired = visible.count > 2 ? safeTop + 153 : safeTop + 212
            } else {
                desired = safeTop + 60
            }
            let maxTop = bottom - CGFloat(rows) * height - CGFloat(max(0, rows - 1)) * 16 - 10
            top = min(desired, maxTop)
        } else {
            // A single tab is centered in the open area. Keep the same anchor
            // when the teaching card fades so the card does not jump during
            // the close transition.
            let desired = safeTop + 210
            let maxTop = bottom - height - 10
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
        if hasLaidOut {
            layoutCards(animated: animated)
        }
        let animations = { [weak self] in
            guard let self else { return }
            self.hintCard.alpha = self.isPrivateMode ? 0 : (visible ? 1 : 0)
        }
        if animated {
            UIView.animate(withDuration: 0.25, animations: animations)
        } else {
            animations()
        }
    }

    private func select(id: MobileTerminalPreview.ID) {
        guard !isTransitioning, !isPrivateMode, let card = cards[id] else { return }
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
        guard !isTransitioning, !isPrivateMode, let card = cards[id] else { return }
        guard visibleItems.count > 1 else { return }
        isTransitioning = true
        removedIDs.insert(id)
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
                self.isTransitioning = false
                // Let the local shrink and reflow finish before SwiftUI updates
                // the source collection. Calling this earlier can cause
                // update() to remove the card before its close animation runs.
                self.onClose(id)
            }
        )
    }

    @objc private func searchTapped() {
        guard searchOverlay == nil else { return }
        let overlay = TerminalTabOverviewSearchOverlay()
        overlay.onClose = { [weak self] in
            self?.dismissSearch(animated: true)
        }
        overlay.onTextChanged = { [weak self] text in
            self?.filterCards(for: text)
        }
        overlay.translatesAutoresizingMaskIntoConstraints = true
        overlay.frame = view.bounds
        view.addSubview(overlay)
        searchOverlay = overlay
        UIView.animate(withDuration: 0.2, delay: 0, options: [.beginFromCurrentState]) {
            self.topBar.alpha = 0
            self.bottomBar.alpha = 0
        }
        UIView.animate(withDuration: 0.32, delay: 0, options: [.curveEaseOut]) {
            overlay.alpha = 1
        }
        // Safari focuses its tab search as the overlay arrives, which brings
        // up the keyboard and makes the search affordance immediately usable.
        overlay.searchField.becomeFirstResponder()
        UIAccessibility.post(notification: .screenChanged, argument: overlay.searchField)
    }

    @objc private func newTerminalTapped() {
        guard !isTransitioning else { return }
        if isPrivateMode {
            // Safari uses the first private-tab creation as the entry point for
            // its locked-private explanation. Keep the existing private canvas
            // visible underneath the sheet instead of changing modes again.
            presentPrivateLock(animated: true)
            return
        }
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
        guard !isTransitioning else { return }
        setPrivateMode(groupControl.selectedSegmentIndex == 0, animated: true)
    }

    private func dismissSearch(animated: Bool) {
        guard let overlay = searchOverlay else { return }
        let finish = { [weak self] in
            overlay.removeFromSuperview()
            self?.searchOverlay = nil
            self?.filterCards(for: "")
            self?.view.setNeedsLayout()
            self?.view.layoutIfNeeded()
            self?.layoutCards(animated: false)
            UIView.animate(withDuration: 0.2) {
                self?.topBar.alpha = 1
                self?.bottomBar.alpha = 1
            }
        }
        guard animated else {
            finish()
            return
        }
        UIView.animate(withDuration: 0.24, animations: {
            overlay.alpha = 0
        }, completion: { _ in finish() })
    }

    private func filterCards(for text: String) {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else {
            cards.values.forEach { $0.alpha = 1 }
            return
        }
        cards.forEach { _, card in
            card.alpha = card.itemTitle.lowercased().contains(query) ? 1 : 0.18
        }
    }

    private func setPrivateMode(_ privateMode: Bool, animated: Bool) {
        guard privateMode != isPrivateMode else { return }
        let regularViews: [UIView] = [hintCard] + Array(cards.values)
        let horizontalOffset = view.bounds.width
        isPrivateMode = privateMode
        groupControl.selectedSegmentIndex = privateMode ? 0 : 1
        if !privateMode {
            dismissPrivateLock(animated: false)
        }

        // Safari keeps the fixed chrome in place and pages the tab content
        // horizontally. Prepare both pages before layoutChrome updates their
        // frames so the transition remains a single UIKit transaction.
        regularViews.forEach {
            $0.isHidden = false
            $0.alpha = 1
            $0.transform = privateMode
                ? .identity
                : CGAffineTransform(translationX: horizontalOffset, y: 0)
        }
        privateBrowsingView.isHidden = false
        privateBrowsingView.alpha = 1
        privateBrowsingView.transform = privateMode
            ? CGAffineTransform(translationX: -horizontalOffset, y: 0)
            : .identity
        groupControl.isUserInteractionEnabled = false

        let changes = { [weak self] in
            guard let self else { return }
            self.layoutButton.isHidden = privateMode
            self.presentationBottomBackdrop?.backgroundColor = self.bottomCanvasColor
            self.view.setNeedsLayout()
            self.view.layoutIfNeeded()
            regularViews.forEach {
                $0.transform = privateMode ? CGAffineTransform(translationX: horizontalOffset, y: 0) : .identity
            }
            self.privateBrowsingView.transform = privateMode ? .identity : CGAffineTransform(translationX: -horizontalOffset, y: 0)
            self.hintCard.alpha = privateMode ? 0 : (self.hintIsVisible ? 1 : 0)
            UIAccessibility.post(
                notification: .screenChanged,
                argument: privateMode ? self.privateBrowsingView : self.groupControl
            )
        }
        let finish = { [weak self] in
            guard let self else { return }
            self.groupControl.isUserInteractionEnabled = true
            regularViews.forEach {
                $0.transform = .identity
                $0.isHidden = privateMode
            }
            self.privateBrowsingView.transform = .identity
            self.privateBrowsingView.isHidden = !privateMode
            self.privateBrowsingView.alpha = 1
            self.hintCard.alpha = privateMode ? 0 : (self.hintIsVisible ? 1 : 0)
            self.isTransitioning = false
        }
        if animated {
            isTransitioning = true
            UIView.animate(
                withDuration: 0.36,
                delay: 0,
                options: [.curveEaseInOut, .beginFromCurrentState],
                animations: changes,
                completion: { _ in finish() }
            )
        } else {
            changes()
            finish()
        }
    }

    private func dismissPrivateLock(animated: Bool) {
        guard !privateLockView.isHidden else { return }
        let finish = {
            self.privateLockView.isHidden = true
            self.privateLockView.alpha = 1
            self.privateLockView.transform = .identity
            self.presentationBottomBackdrop?.backgroundColor = self.bottomCanvasColor
            self.view.bringSubviewToFront(self.topBar)
            self.view.bringSubviewToFront(self.bottomBar)
            self.view.bringSubviewToFront(self.privateBrowsingView)
            UIAccessibility.post(notification: .screenChanged, argument: self.privateBrowsingView)
        }
        guard animated else {
            finish()
            return
        }
        UIView.animate(withDuration: 0.28, delay: 0, options: [.curveEaseIn, .beginFromCurrentState], animations: {
            self.privateLockView.alpha = 0
            self.privateLockView.transform = CGAffineTransform(translationX: 0, y: self.privateLockView.bounds.height)
        }, completion: { _ in finish() })
    }

    private func presentPrivateLock(animated: Bool) {
        guard isPrivateMode, privateLockView.isHidden else { return }
        privateLockView.isHidden = false
        privateLockView.alpha = 0
        privateLockView.transform = CGAffineTransform(translationX: 0, y: privateLockView.bounds.height)
        presentationBottomBackdrop?.backgroundColor = privateLockColor
        view.bringSubviewToFront(privateLockView)
        UIAccessibility.post(notification: .screenChanged, argument: privateLockView)
        let animations = {
            self.privateLockView.alpha = 1
            self.privateLockView.transform = .identity
        }
        if animated {
            UIView.animate(
                withDuration: 0.34,
                delay: 0,
                options: [.curveEaseOut, .beginFromCurrentState],
                animations: animations
            )
        } else {
            animations()
        }
    }

    private func reorder(id: MobileTerminalPreview.ID, at location: CGPoint) {
        let visible = visibleItems
        guard let currentIndex = visible.firstIndex(where: { $0.id == id }) else { return }
        let targetIndex = visible.enumerated()
            .filter { $0.element.id != id }
            .min { lhs, rhs in
                let left = cards[lhs.element.id].map { hypot($0.center.x - location.x, $0.center.y - location.y) } ?? .greatestFiniteMagnitude
                let right = cards[rhs.element.id].map { hypot($0.center.x - location.x, $0.center.y - location.y) } ?? .greatestFiniteMagnitude
                return left < right
            }
            .map(\.offset) ?? currentIndex
        guard targetIndex != currentIndex else { return }
        var order = visible
        let moved = order.remove(at: currentIndex)
        order.insert(moved, at: min(targetIndex, order.count))
        let visibleIDs = Set(visible.map(\.id))
        var next = order
        next.append(contentsOf: items.filter { !visibleIDs.contains($0.id) })
        items = next
        manualOrderIDs = next.map(\.id)
        layoutCards(animated: true)
    }

    private func dragChanged(id: MobileTerminalPreview.ID, state: UIGestureRecognizer.State, location: CGPoint) {
        guard !isPrivateMode, let card = cards[id] else { return }
        switch state {
        case .began:
            draggingID = id
            card.layer.zPosition = 20
            UIView.animate(withDuration: 0.18) {
                card.transform = CGAffineTransform(scaleX: 1.04, y: 1.04)
                card.layer.shadowOpacity = 0.24
                card.layer.shadowRadius = 18
            }
        case .changed:
            card.center = location
        case .ended, .cancelled, .failed:
            reorder(id: id, at: location)
            draggingID = nil
            UIView.animate(withDuration: 0.28, delay: 0, usingSpringWithDamping: 0.86, initialSpringVelocity: 0.1) {
                card.transform = .identity
                card.layer.shadowOpacity = 0.13
                card.layer.shadowRadius = 12
            } completion: { _ in
                card.layer.zPosition = 0
            }
        default:
            break
        }
    }
}

@MainActor
private final class TerminalTabOverviewPrivateView: UIView {
    private let handView = UIImageView(image: UIImage(systemName: "hand.raised.fill"))
    private let titleLabel = UILabel()
    private let messageLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isAccessibilityElement = false

        handView.tintColor = .secondaryLabel
        handView.contentMode = .scaleAspectFit
        addSubview(handView)

        titleLabel.text = "Private Browsing"
        titleLabel.textColor = .secondaryLabel
        titleLabel.font = .systemFont(ofSize: 24, weight: .regular)
        titleLabel.textAlignment = .center
        addSubview(titleLabel)

        messageLabel.text = "Private Browsing adds additional privacy protections for tabs. After you close a tab, Safari won’t remember the pages you visited, your search history, or your AutoFill information."
        messageLabel.textColor = .secondaryLabel
        messageLabel.font = .systemFont(ofSize: 16, weight: .regular)
        messageLabel.textAlignment = .center
        messageLabel.numberOfLines = 0
        messageLabel.adjustsFontSizeToFitWidth = true
        messageLabel.minimumScaleFactor = 0.86
        addSubview(messageLabel)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let contentWidth = min(bounds.width - 12, 360)
        let centerX = bounds.midX
        let centerY = bounds.midY - 93
        handView.frame = CGRect(x: centerX - 29, y: centerY - 46, width: 58, height: 58)
        titleLabel.frame = CGRect(x: centerX - contentWidth / 2, y: centerY + 20, width: contentWidth, height: 34)
        messageLabel.frame = CGRect(x: centerX - contentWidth / 2, y: centerY + 68, width: contentWidth, height: 125)
    }
}

@MainActor
private final class TerminalTabOverviewPrivateLockView: UIView {
    var onDismiss: (() -> Void)?

    private let iconView = UIImageView(image: UIImage(systemName: "hand.raised.fill"))
    private let lockBadge = UIImageView(image: UIImage(systemName: "faceid"))
    private let titleLabel = UILabel()
    private let messageLabel = UILabel()
    private let enableButton = UIButton(type: .system)
    private let notNowButton = UIButton(type: .system)

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor(red: 0.095, green: 0.095, blue: 0.095, alpha: 1)
        layer.cornerRadius = 30
        layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        layer.masksToBounds = true
        isAccessibilityElement = false

        iconView.tintColor = .white
        iconView.contentMode = .scaleAspectFit
        addSubview(iconView)

        lockBadge.tintColor = .white
        lockBadge.backgroundColor = .clear
        lockBadge.contentMode = .scaleAspectFit
        addSubview(lockBadge)

        titleLabel.text = "Locked Private Browsing"
        titleLabel.textColor = .white
        titleLabel.font = .systemFont(ofSize: 22, weight: .semibold)
        titleLabel.textAlignment = .center
        addSubview(titleLabel)

        messageLabel.text = "Private Browsing will lock when you leave Safari, leave Private Browsing, or lock your iPhone.\n\nYou can unlock Private Browsing with Face ID or your passcode.\n\nYou can change this later in Safari Settings."
        messageLabel.textColor = UIColor.white.withAlphaComponent(0.72)
        messageLabel.font = .systemFont(ofSize: 18, weight: .regular)
        messageLabel.textAlignment = .center
        messageLabel.numberOfLines = 0
        addSubview(messageLabel)

        enableButton.setTitle("Turn On Locked Private Browsing", for: .normal)
        enableButton.titleLabel?.font = .systemFont(ofSize: 15, weight: .semibold)
        enableButton.configureLiquidGlass(
            title: "Turn On Locked Private Browsing",
            prominent: true,
            foregroundColor: .white
        )
        enableButton.accessibilityLabel = "Turn On Locked Private Browsing"
        enableButton.accessibilityIdentifier = "MobileTerminalOverviewEnablePrivateLock"
        enableButton.addTarget(self, action: #selector(dismissTapped), for: .touchUpInside)
        addSubview(enableButton)

        notNowButton.setTitle("Not Now", for: .normal)
        notNowButton.titleLabel?.font = .systemFont(ofSize: 15, weight: .medium)
        notNowButton.configureLiquidGlass(
            title: "Not Now",
            prominent: false,
            foregroundColor: .white
        )
        notNowButton.accessibilityLabel = "Not Now"
        notNowButton.accessibilityIdentifier = "MobileTerminalOverviewPrivateNotNow"
        notNowButton.addTarget(self, action: #selector(dismissTapped), for: .touchUpInside)
        addSubview(notNowButton)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let width = min(bounds.width - 64, 338)
        let centerX = bounds.midX
        let contentTop = max(112, bounds.height * 0.09)
        iconView.frame = CGRect(x: centerX - 31, y: contentTop, width: 62, height: 62)
        lockBadge.frame = CGRect(x: centerX + 12, y: contentTop + 45, width: 28, height: 28)
        titleLabel.frame = CGRect(x: centerX - width / 2, y: contentTop + 242, width: width, height: 32)
        messageLabel.frame = CGRect(x: centerX - width / 2, y: contentTop + 300, width: width, height: 208)
        enableButton.frame = CGRect(x: centerX - width / 2, y: bounds.maxY - 120, width: width, height: 44)
        notNowButton.frame = CGRect(x: centerX - width / 2, y: bounds.maxY - 66, width: width, height: 40)
    }

    @objc private func dismissTapped() {
        onDismiss?()
    }
}

@MainActor
private final class TerminalTabOverviewSearchOverlay: UIView {
    var onClose: (() -> Void)?
    var onTextChanged: ((String) -> Void)?
    let searchField = UITextField()

    private var keyboardBottomInset: CGFloat = 0

    private let blurView = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterialLight))
    private let searchContainer = UIView()
    private let searchMaterial = UIVisualEffectView(effect: nil)
    private let searchIcon = UIImageView(image: UIImage(systemName: "magnifyingglass"))
    private let microphoneButton = UIButton(type: .system)
    private let closeButton = UIButton(type: .system)
    private let searchCaret = UIView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        alpha = 0
        backgroundColor = .clear
        accessibilityViewIsModal = true

        blurView.translatesAutoresizingMaskIntoConstraints = true
        blurView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(blurView)

        searchContainer.backgroundColor = .clear
        searchContainer.layer.cornerRadius = 23
        searchContainer.clipsToBounds = true
        addSubview(searchContainer)

        searchMaterial.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        searchMaterial.layer.cornerRadius = 23
        searchMaterial.clipsToBounds = true
        searchMaterial.configureLiquidGlass(fallback: .systemMaterial)
        searchContainer.addSubview(searchMaterial)

        searchIcon.tintColor = .label
        searchIcon.contentMode = .scaleAspectFit
        searchContainer.addSubview(searchIcon)

        searchField.attributedPlaceholder = NSAttributedString(
            string: "Search Tabs",
            attributes: [.foregroundColor: UIColor.secondaryLabel]
        )
        searchField.font = .systemFont(ofSize: 20, weight: .regular)
        searchField.textColor = .label
        searchField.tintColor = .systemBlue
        searchField.borderStyle = .none
        searchField.returnKeyType = .done
        searchField.accessibilityLabel = "Search Tabs"
        searchField.accessibilityIdentifier = "MobileTerminalOverviewSearchField"
        searchField.addTarget(self, action: #selector(textChanged), for: .editingChanged)
        searchContainer.addSubview(searchField)

        searchCaret.backgroundColor = .systemBlue
        searchCaret.layer.cornerRadius = 1
        searchCaret.isHidden = true
        searchContainer.addSubview(searchCaret)

        microphoneButton.setImage(UIImage(systemName: "mic.fill"), for: .normal)
        microphoneButton.tintColor = .label
        microphoneButton.accessibilityLabel = "Dictate Search"
        searchContainer.addSubview(microphoneButton)

        closeButton.setImage(UIImage(systemName: "xmark"), for: .normal)
        closeButton.configureLiquidGlass(
            imageName: "xmark",
            prominent: false,
            symbolPointSize: 20
        )
        closeButton.accessibilityLabel = "Close Search"
        closeButton.accessibilityIdentifier = "MobileTerminalOverviewSearchClose"
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        addSubview(closeButton)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(keyboardWillChangeFrame(_:)),
            name: UIResponder.keyboardWillChangeFrameNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(keyboardWillHide(_:)),
            name: UIResponder.keyboardWillHideNotification,
            object: nil
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        blurView.frame = bounds
        // Safari leaves a small breathing space between the tab-search bar
        // and the keyboard. The keyboard is a separate window, so the root
        // view does not resize for it; track its overlap explicitly.
        let keyboardSpacing: CGFloat = keyboardBottomInset > 0 ? 10 : 0
        let bottom = max(0, safeAreaInsets.bottom - 2) + keyboardBottomInset + keyboardSpacing
        let closeSize: CGFloat = 45
        closeButton.frame = CGRect(x: bounds.width - 61, y: bounds.height - bottom - closeSize, width: closeSize, height: closeSize)
        searchContainer.frame = CGRect(x: 16, y: bounds.height - bottom - 45, width: max(0, bounds.width - 85), height: 45)
        searchMaterial.frame = searchContainer.bounds
        searchIcon.frame = CGRect(x: 15, y: 9, width: 28, height: 28)
        microphoneButton.frame = CGRect(x: searchContainer.bounds.width - 48, y: 0, width: 44, height: 45)
        searchField.frame = CGRect(x: 49, y: 0, width: max(0, searchContainer.bounds.width - 96), height: 45)
        searchCaret.frame = CGRect(x: 79, y: 9, width: 2, height: 27)
    }

    @objc private func closeTapped() {
        onClose?()
    }

    @objc private func keyboardWillChangeFrame(_ notification: Notification) {
        updateKeyboardInset(from: notification)
    }

    @objc private func keyboardWillHide(_ notification: Notification) {
        keyboardBottomInset = 0
        animateKeyboardLayout(using: notification)
    }

    private func updateKeyboardInset(from notification: Notification) {
        guard
            let value = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue,
            let window
        else { return }

        let frameInWindow = window.convert(value.cgRectValue, from: nil)
        let frameInOverlay = convert(frameInWindow, from: window)
        let overlap = bounds.intersection(frameInOverlay)
        keyboardBottomInset = overlap.isNull ? 0 : max(0, bounds.maxY - overlap.minY)
        animateKeyboardLayout(using: notification)
    }

    private func animateKeyboardLayout(using notification: Notification) {
        let duration = (notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? NSNumber)?.doubleValue ?? 0.25
        let curveRaw = (notification.userInfo?[UIResponder.keyboardAnimationCurveUserInfoKey] as? NSNumber)?.uintValue ?? 7
        let curve = UIView.AnimationOptions(rawValue: curveRaw << 16)
        UIView.animate(withDuration: duration, delay: 0, options: [curve, .beginFromCurrentState]) {
            self.setNeedsLayout()
            self.layoutIfNeeded()
        }
    }

    @objc private func textChanged() {
        let text = searchField.text ?? ""
        searchCaret.isHidden = true
        onTextChanged?(text)
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
            defaultValue: "While viewing a web page, you can swipe up from the search field to quickly view all open tabs."
        )
        messageLabel.font = .systemFont(ofSize: 17, weight: .regular)
        messageLabel.textColor = .secondaryLabel
        messageLabel.numberOfLines = 3
        addSubview(messageLabel)

        // Safari renders the card teaching affordance as the filled SF Symbol
        // itself. The symbol supplies the circular treatment, so there is no
        // second painted button background beneath the system material.
        closeButton.setImage(UIImage(systemName: "xmark.circle.fill"), for: .normal)
        closeButton.setPreferredSymbolConfiguration(
            UIImage.SymbolConfiguration(pointSize: 22, weight: .regular),
            forImageIn: .normal
        )
        closeButton.tintColor = .secondaryLabel
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
        let compact = bounds.height > 0 && (frame.minY <= 70 || bounds.height <= 145)
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

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard !isHidden, alpha > 0.01, bounds.contains(point) else { return nil }
        let closePoint = closeButton.convert(point, from: self)
        guard closeButton.bounds.contains(closePoint) else { return nil }
        return closeButton.hitTest(closePoint, with: event)
    }

    @objc private func closeTapped() {
        onClose?()
    }
}

@MainActor
private final class TerminalTabOverviewCardView: UIControl {
    var onSelect: ((MobileTerminalPreview.ID) -> Void)?
    var onClose: ((MobileTerminalPreview.ID) -> Void)?
    var onDrag: ((MobileTerminalPreview.ID, UIGestureRecognizer.State, CGPoint) -> Void)?

    private var item: TerminalTabOverviewItem
    private let surface = UIView()
    private let preview = UIView()
    private let titleLabel = UILabel()
    private let bottomTitleLabel = UILabel()
    private let groupIcon = UIImageView(image: UIImage(systemName: "square.grid.3x3.fill"))
    private let closeButton = UIButton(type: .system)
    private let lineStack = UIStackView()
    private let bodyStack = UIStackView()

    init(item: TerminalTabOverviewItem, canClose: Bool) {
        self.item = item
        super.init(frame: .zero)
        isAccessibilityElement = true
        accessibilityTraits = .button
        configure()
        update(item: item, canClose: canClose)
    }

    var itemTitle: String { item.title }

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
        bodyStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let bodyLines = lines.suffix(3)
        for line in bodyLines {
            let bodyLine = makeLine(line.isEmpty ? " " : line, muted: true)
            bodyLine.textColor = UIColor.secondaryLabel.withAlphaComponent(0.82)
            bodyStack.addArrangedSubview(bodyLine)
        }
        setNeedsLayout()
    }

    private func configure() {
        backgroundColor = UIColor.secondarySystemBackground
        layer.cornerRadius = 19
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.13
        layer.shadowRadius = 12
        layer.shadowOffset = CGSize(width: 0, height: 6)
        layer.masksToBounds = false
        addTarget(self, action: #selector(selected), for: .touchUpInside)
        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(longPressed(_:)))
        longPress.minimumPressDuration = 0.28
        longPress.allowableMovement = 80
        longPress.cancelsTouchesInView = true
        addGestureRecognizer(longPress)

        surface.backgroundColor = .systemBackground
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

        bodyStack.axis = .vertical
        bodyStack.alignment = .fill
        bodyStack.distribution = .fill
        bodyStack.spacing = 2
        bodyStack.isUserInteractionEnabled = false
        addSubview(bodyStack)

        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        titleLabel.textColor = .label
        titleLabel.lineBreakMode = .byTruncatingTail
        surface.addSubview(titleLabel)

        bottomTitleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        bottomTitleLabel.textColor = .label
        bottomTitleLabel.lineBreakMode = .byTruncatingTail
        addSubview(bottomTitleLabel)

        groupIcon.tintColor = .secondaryLabel
        groupIcon.contentMode = .scaleAspectFit
        addSubview(groupIcon)

        // Card close controls use Safari's filled SF Symbol. Keeping this as
        // an image preserves the symbol's native gray circle and avoids a
        // hand-painted background behind the card preview.
        closeButton.setImage(UIImage(systemName: "xmark.circle.fill"), for: .normal)
        closeButton.setPreferredSymbolConfiguration(
            UIImage.SymbolConfiguration(pointSize: 22, weight: .regular),
            forImageIn: .normal
        )
        closeButton.tintColor = .secondaryLabel
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
        let surfaceHeight: CGFloat = bounds.height > 300 ? 178 : 146
        surface.frame = CGRect(
            x: inset,
            y: inset,
            width: max(0, bounds.width - inset * 2),
            height: max(0, min(surfaceHeight, bounds.height - inset * 2))
        )
        let closeSize: CGFloat = 30
        closeButton.frame = CGRect(x: bounds.width - closeSize - 4, y: 4, width: closeSize, height: closeSize)
        let titleY: CGFloat = 14
        titleLabel.frame = CGRect(x: 16, y: titleY, width: max(0, surface.bounds.width - 32), height: 22)
        preview.frame = CGRect(
            x: 8,
            y: titleY + 30,
            width: max(0, surface.bounds.width - 16),
            height: max(0, surface.bounds.height - titleY - 38)
        )
        lineStack.frame = preview.bounds.insetBy(dx: 9, dy: 8)
        bodyStack.frame = CGRect(
            x: 16,
            y: surface.frame.maxY + 12,
            width: max(0, bounds.width - 32),
            height: max(0, bounds.height - surface.frame.maxY - 48)
        )
        let bottomY = bounds.height - 30
        groupIcon.frame = CGRect(x: 16, y: bottomY, width: 16, height: 16)
        bottomTitleLabel.frame = CGRect(x: 38, y: bottomY - 2, width: max(0, bounds.width - 50), height: 22)
    }

    @objc private func selected() {
        onSelect?(item.id)
    }

    @objc private func closeTapped() {
        onClose?(item.id)
    }

    @objc private func longPressed(_ gesture: UILongPressGestureRecognizer) {
        let location = gesture.location(in: superview)
        onDrag?(item.id, gesture.state, location)
    }
}
#endif
