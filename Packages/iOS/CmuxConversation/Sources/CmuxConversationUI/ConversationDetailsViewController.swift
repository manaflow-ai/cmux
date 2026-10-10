#if canImport(UIKit)
import CmuxConversationCore
import CmuxConversationGeometry
import UIKit

/// Conversation details as Messages presents them on iOS 26 and 27
/// (ChatKit's CommunicationDetails): a full-screen page over the blurred
/// transcript, zoomed out of the header's avatar, with a collapsing header
/// (avatar, title, call / video / mail) and Info / Backgrounds pages.
///
/// The presenter sets `modalPresentationStyle = .overFullScreen` and a zoom
/// `preferredTransition` from the header's avatar (`ConversationDetailsPresentation`),
/// as Messages does, so UIKit drives the open and close springs on each OS.
final class ConversationDetailsViewController: UIViewController, UIScrollViewDelegate {
    let store: ConversationStore
    private var info: ConversationInfo
    private let meID: String?
    let infoPage: ConversationDetailsInfoPage
    private var backgroundsPage: ConversationDetailsBackgroundsPage?

    /// Messages' backdrop: the transcript blurred at radius 16 under a 60 %
    /// wash of the background color.
    private let blur = UIVisualEffectView(effect: nil)
    private var blurAnimator: UIViewPropertyAnimator?
    private let wash = UIView()
    private let pages = UIScrollView()
    private let header = ConversationDetailsHeaderView()
    let tabBar: ConversationDetailsTabBar?
    let backGlass = makeGlassView(cornerRadius: ConversationHeaderGeometry.buttonSize / 2, interactive: true)
    private let backButton = UIButton(type: .system)

    /// Opens the background editor for a category (the Backgrounds page).
    var onEditBackground: ((ConversationBackground.Kind?) -> Void)?
    var onClose: (() -> Void)?

    var background: ConversationBackground? {
        didSet { backgroundsPage?.current = background }
    }

    init?(store: ConversationStore, showsBackgrounds: Bool) {
        guard let info = store.info else { return nil }
        self.store = store
        self.info = info
        meID = store.meID
        infoPage = ConversationDetailsInfoPage(store: store)
        tabBar = showsBackgrounds ? ConversationDetailsTabBar(titles: [
            // DETAILS_INFO_TAB / DETAILS_BACKGROUNDS_TAB
            String(localized: "conversation.details.tab.info", defaultValue: "Info", bundle: .module),
            ConversationBackgroundStrings.backgrounds,
        ]) : nil
        super.init(nibName: nil, bundle: nil)
        if showsBackgrounds { backgroundsPage = ConversationDetailsBackgroundsPage() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private var isGroup: Bool { info.kind == .group }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        view.accessibilityViewIsModal = true
        blur.frame = view.bounds
        blur.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(blur)
        wash.frame = view.bounds
        wash.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        wash.backgroundColor = UIColor { ($0.userInterfaceStyle == .dark ? UIColor.black : UIColor.white).withAlphaComponent(0.6) }
        wash.isUserInteractionEnabled = false
        view.addSubview(wash)

        pages.isPagingEnabled = true
        pages.showsHorizontalScrollIndicator = false
        pages.contentInsetAdjustmentBehavior = .never
        pages.delegate = self
        pages.isScrollEnabled = backgroundsPage != nil
        view.addSubview(pages)
        infoPage.table.delegate = infoPage
        infoPage.onScroll = { [weak self] in self?.layoutHeader() }
        pages.addSubview(infoPage.table)
        if let backgroundsPage {
            backgroundsPage.current = background
            backgroundsPage.onScroll = { [weak self] in self?.layoutHeader() }
            backgroundsPage.onSelect = { [weak self] kind in self?.onEditBackground?(kind) }
            pages.addSubview(backgroundsPage.scroll)
        }

        header.configure(info: info, meID: meID)
        view.addSubview(header)
        if let tabBar {
            tabBar.onSelect = { [weak self] index in self?.showPage(index, animated: true) }
            view.addSubview(tabBar)
        }

        backButton.setImage(UIImage(systemName: "chevron.left", withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold)), for: .normal)
        backButton.tintColor = .label
        backButton.accessibilityLabel = String(localized: "conversation.header.back", defaultValue: "Back", bundle: .module)
        backButton.accessibilityIdentifier = "conversation.details.back"
        backButton.addAction(UIAction { [weak self] _ in self?.close() }, for: .touchUpInside)
        backGlass.contentView.addSubview(backButton)
        view.addSubview(backGlass)
        accessibilityElementsOrder()
    }

    private func accessibilityElementsOrder() {
        var elements: [Any] = [backGlass, header]
        if let tabBar { elements.append(tabBar) }
        elements.append(pages)
        view.accessibilityElements = elements
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        applyBlur()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        UIAccessibility.post(notification: .screenChanged, argument: header.titleLabel)
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if previousTraitCollection?.userInterfaceStyle != traitCollection.userInterfaceStyle {
            blurAnimator?.stopAnimation(true)
            blurAnimator = nil
            blur.effect = nil
            applyBlur()
        }
    }

    /// UIKit has no public blur radius; a paused animator holds the dark
    /// (light) blur at the share of its strength that is radius 16.
    private func applyBlur() {
        guard blurAnimator == nil else { return }
        let style: UIBlurEffect.Style = traitCollection.userInterfaceStyle == .dark ? .dark : .light
        let animator = UIViewPropertyAnimator(duration: 1, curve: .linear)
        animator.addAnimations { [blur] in blur.effect = UIBlurEffect(style: style) }
        animator.pausesOnCompletion = true
        animator.fractionComplete = Self.blurShareOfStyle
        blurAnimator = animator
    }

    /// Radius 16 of the style's ~30 (see `ConversationViewController.blurShareOfStyle`).
    static let blurShareOfStyle: CGFloat = 16.0 / 30.0

    deinit {
        MainActor.assumeIsolated {
            blurAnimator?.stopAnimation(true)
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let bounds = view.bounds
        pages.frame = bounds
        let count = backgroundsPage == nil ? 1 : 2
        pages.contentSize = CGSize(width: bounds.width * CGFloat(count), height: bounds.height)
        infoPage.table.frame = bounds
        backgroundsPage?.scroll.frame = bounds.offsetBy(dx: bounds.width, dy: 0)
        let top = view.safeAreaInsets.top
        let margin = ConversationHeaderGeometry.sideMargin(layoutMargin: view.layoutMargins.left)
        backGlass.frame = CGRect(x: margin, y: top, width: ConversationHeaderGeometry.buttonSize, height: ConversationHeaderGeometry.buttonSize)
        backButton.frame = CGRect(x: 2, y: ConversationHeaderGeometry.backChevronDrop, width: 40, height: 44)
        let rest = ConversationDetailsHeaderGeometry.layout(width: bounds.width, safeTop: top, offset: 0, showsTabs: tabBar != nil, isGroup: isGroup)
        infoPage.setHeaderHeight(rest.height, bottomInset: view.safeAreaInsets.bottom)
        backgroundsPage?.setHeaderHeight(rest.height, bottomInset: view.safeAreaInsets.bottom)
        layoutHeader()
    }

    /// The current page's scroll offset drives the header.
    private var currentOffset: CGFloat {
        let fraction = pageFraction
        let infoOffset = infoPage.table.contentOffset.y + infoPage.table.adjustedContentInset.top
        guard let backgroundsPage else { return infoOffset }
        let backgroundsOffset = backgroundsPage.scroll.contentOffset.y + backgroundsPage.scroll.adjustedContentInset.top
        return infoOffset + (backgroundsOffset - infoOffset) * fraction
    }

    private var pageFraction: CGFloat {
        guard pages.bounds.width > 0 else { return 0 }
        return max(0, min(1, pages.contentOffset.x / pages.bounds.width))
    }

    private func layoutHeader() {
        let bounds = view.bounds
        guard bounds.width > 0 else { return }
        let layout = ConversationDetailsHeaderGeometry.layout(width: bounds.width, safeTop: view.safeAreaInsets.top, offset: currentOffset, showsTabs: tabBar != nil, isGroup: isGroup)
        header.frame = CGRect(x: 0, y: 0, width: bounds.width, height: max(layout.quickActions.maxY, layout.titleTop + ConversationDetailsHeaderGeometry.titleHeight))
        header.apply(layout)
        if let tabBar {
            tabBar.frame = layout.tabBar
            tabBar.selection = pageFraction
        }
    }

    // MARK: Pages

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard scrollView === pages else { return }
        layoutHeader()
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        guard scrollView === pages else { return }
        tabBar?.selectedIndex = Int(round(pageFraction))
    }

    func showPage(_ index: Int, animated: Bool) {
        tabBar?.selectedIndex = index
        pages.setContentOffset(CGPoint(x: CGFloat(index) * pages.bounds.width, y: 0), animated: animated)
        UIAccessibility.post(notification: .layoutChanged, argument: index == 0 ? infoPage.table : backgroundsPage?.scroll)
    }

    // MARK: Store

    func storeDidChange(_ change: ConversationStoreChange) {
        if let info = store.info, info != self.info {
            self.info = info
            header.configure(info: info, meID: meID)
        }
        infoPage.storeDidChange(change)
    }

    // MARK: Closing

    func close() {
        onClose?()
    }

    override func accessibilityPerformEscape() -> Bool {
        close()
        return true
    }
}

/// The details header: avatar (or group cluster), title and the call /
/// video / mail circles. The title scales about its top center as it
/// collapses.
final class ConversationDetailsHeaderView: UIView {
    private var avatars: [ConversationAvatarView] = []
    private let clusterDisc = makeGlassView(cornerRadius: 40)
    let titleLabel = UILabel()
    private let actions = UIStackView()
    private(set) var actionButtons: [UIButton] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        clusterDisc.isHidden = true
        clusterDisc.isUserInteractionEnabled = false
        addSubview(clusterDisc)
        titleLabel.font = ConversationDetailsHeaderView.titleFont
        titleLabel.textAlignment = .center
        titleLabel.textColor = .label
        titleLabel.adjustsFontSizeToFitWidth = true
        titleLabel.minimumScaleFactor = 0.6
        titleLabel.accessibilityTraits = .header
        titleLabel.accessibilityIdentifier = "conversation.details.title"
        titleLabel.layer.anchorPoint = CGPoint(x: 0.5, y: 0)
        addSubview(titleLabel)
        actions.axis = .horizontal
        actions.spacing = ConversationDetailsHeaderGeometry.quickActionSpacing
        actions.distribution = .fillEqually
        // CommunicationDetails' QuickActionView: a 48 pt circle in the
        // tertiary fill with the filled glyph; unavailable ones dim the glyph.
        let items: [(String, String, String)] = [
            ("phone.fill", String(localized: "conversation.details.call", defaultValue: "Call", bundle: .module), "call"),
            ("video.fill", String(localized: "conversation.ax.facetime", defaultValue: "FaceTime", bundle: .module), "video"),
            ("envelope.fill", String(localized: "conversation.details.mail", defaultValue: "Mail", bundle: .module), "mail"),
        ]
        for (symbol, label, id) in items {
            let button = UIButton(type: .custom)
            button.backgroundColor = .tertiarySystemFill
            button.layer.cornerRadius = ConversationDetailsHeaderGeometry.quickActionSize / 2
            // phone.fill is 19.67 x 17.67 pt: the body style's symbol.
            let image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(textStyle: .body))
            button.setImage(image, for: .normal)
            button.tintColor = .label
            button.adjustsImageWhenDisabled = false
            button.setImage(image?.withTintColor(.tertiaryLabel, renderingMode: .alwaysOriginal), for: .disabled)
            button.accessibilityLabel = label
            button.accessibilityIdentifier = "conversation.details.\(id)"
            button.isEnabled = false
            actions.addArrangedSubview(button)
            actionButtons.append(button)
        }
        addSubview(actions)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// SF 28 bold (Messages' `.title.bold()`; ink "+1 (888) 555-1212" 245.67 pt).
    static var titleFont: UIFont { .systemFont(ofSize: 28, weight: .bold) }

    func configure(info: ConversationInfo, meID: String?) {
        titleLabel.text = info.title
        let others = info.participants.filter { $0.id != meID }
        let shown = info.kind == .group ? Array(others.prefix(3)) : Array(others.prefix(1))
        avatars.forEach { $0.removeFromSuperview() }
        avatars = shown.map { participant in
            let view = ConversationAvatarView()
            view.configure(initials: participant.initials, colorHex: nil)
            view.layer.borderWidth = info.kind == .group ? 2 : 0
            view.layer.borderColor = UIColor.black.withAlphaComponent(0.25).cgColor
            addSubview(view)
            return view
        }
        clusterDisc.isHidden = info.kind != .group
        if let lastLayout { apply(lastLayout) }
    }

    private var lastLayout: ConversationDetailsHeaderLayout?

    func apply(_ layout: ConversationDetailsHeaderLayout) {
        lastLayout = layout
        let square = layout.avatar
        if avatars.count <= 1 {
            avatars.first?.frame = square
        } else {
            // The header's 60 pt cluster, scaled to the square.
            let k = square.width / 60
            clusterDisc.frame = square
            clusterDisc.layer.cornerRadius = square.width / 2
            let origin = square.origin
            avatars[0].frame = CGRect(x: origin.x + 5 * k, y: origin.y + 6 * k, width: 32 * k, height: 32 * k)
            if avatars.count > 1 { avatars[1].frame = CGRect(x: origin.x + 32 * k, y: origin.y + 18 * k, width: 24 * k, height: 24 * k) }
            if avatars.count > 2 { avatars[2].frame = CGRect(x: origin.x + 16 * k, y: origin.y + 36 * k, width: 18 * k, height: 18 * k) }
        }
        let titleWidth = bounds.width - 2 * 40
        titleLabel.transform = .identity
        titleLabel.bounds = CGRect(x: 0, y: 0, width: titleWidth, height: ConversationDetailsHeaderGeometry.titleHeight)
        titleLabel.center = CGPoint(x: bounds.midX, y: layout.titleTop)
        titleLabel.transform = CGAffineTransform(scaleX: layout.titleScale, y: layout.titleScale)
        actions.frame = layout.quickActions
        actions.alpha = layout.quickActionsAlpha
        actions.isUserInteractionEnabled = layout.quickActionsAlpha > 0.5
        actions.accessibilityElementsHidden = layout.quickActionsAlpha == 0
    }

    /// The square the zoom transition aligns with the conversation header's avatar.
    var avatarFrame: CGRect { clusterDisc.isHidden ? (avatars.first?.frame ?? .zero) : clusterDisc.frame }
}

/// Info / Backgrounds: unselected titles in secondary label, the selected
/// one in semibold label inside a glass capsule that follows the pages.
/// The capsule reveals the selected style through a mask, as
/// CommunicationDetails' DetailsTabBarView does, so a half-swiped page
/// shows each title half in each style.
final class ConversationDetailsTabBar: UIView {
    private let titles: [String]
    private var plainLabels: [UILabel] = []
    private var boldLabels: [UILabel] = []
    private let plainLayer = UIView()
    private let boldLayer = UIView()
    private let capsule = makeGlassView(cornerRadius: 16.95)
    private let plainMask = CAShapeLayer()
    private let boldMask = CAShapeLayer()
    private var buttons: [UIButton] = []
    var onSelect: ((Int) -> Void)?
    /// 0 is the first tab, 1 the second; fractions follow a swipe.
    var selection: CGFloat = 0 { didSet { setNeedsLayout() } }
    var selectedIndex = 0 {
        didSet {
            for (index, button) in buttons.enumerated() {
                button.accessibilityTraits = index == selectedIndex ? [.button, .selected] : .button
            }
        }
    }

    static let font = UIFont.systemFont(ofSize: 15, weight: .regular)
    static let selectedFont = UIFont.systemFont(ofSize: 15, weight: .semibold)
    /// Each tab is its title plus 13 pt a side ("Info" is 53.79 pt wide).
    static let padding: CGFloat = 13
    static let capsuleHeight: CGFloat = 33.9

    init(titles: [String]) {
        self.titles = titles
        super.init(frame: .zero)
        addSubview(capsule)
        capsule.isUserInteractionEnabled = false
        addSubview(plainLayer)
        addSubview(boldLayer)
        plainLayer.isUserInteractionEnabled = false
        boldLayer.isUserInteractionEnabled = false
        plainMask.fillRule = .evenOdd
        plainLayer.layer.mask = plainMask
        boldLayer.layer.mask = boldMask
        for (index, title) in titles.enumerated() {
            let plain = UILabel()
            plain.text = title
            plain.font = Self.font
            plain.textColor = .secondaryLabel
            plain.textAlignment = .center
            plainLayer.addSubview(plain)
            plainLabels.append(plain)
            let bold = UILabel()
            bold.text = title
            bold.font = Self.selectedFont
            bold.textColor = .label
            bold.textAlignment = .center
            boldLayer.addSubview(bold)
            boldLabels.append(bold)
            let button = UIButton(type: .custom)
            button.accessibilityLabel = title
            button.accessibilityIdentifier = "conversation.details.tab.\(index)"
            button.addAction(UIAction { [weak self] _ in self?.onSelect?(index) }, for: .touchUpInside)
            addSubview(button)
            buttons.append(button)
        }
        selectedIndex = 0
        isAccessibilityElement = false
        accessibilityElements = buttons
        accessibilityTraits = .tabBar
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private var tabFrames: [CGRect] {
        let widths = titles.map { ($0 as NSString).size(withAttributes: [.font: Self.selectedFont]).width + 2 * Self.padding }
        var x = (bounds.width - widths.reduce(0, +)) / 2
        let y: CGFloat = 0
        return widths.map { width in
            defer { x += width }
            return CGRect(x: x, y: y, width: width, height: Self.capsuleHeight)
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        plainLayer.frame = bounds
        boldLayer.frame = bounds
        let frames = tabFrames
        for index in frames.indices {
            plainLabels[index].frame = frames[index]
            boldLabels[index].frame = frames[index]
            buttons[index].frame = frames[index]
        }
        guard let first = frames.first else { return }
        let last = frames[min(frames.count - 1, 1)]
        let t = max(0, min(1, selection))
        let capsuleFrame = CGRect(
            x: first.minX + (last.minX - first.minX) * t,
            y: first.minY,
            width: first.width + (last.width - first.width) * t,
            height: first.height
        )
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        capsule.frame = capsuleFrame
        let pill = UIBezierPath(roundedRect: capsuleFrame, cornerRadius: capsuleFrame.height / 2)
        boldMask.path = pill.cgPath
        let outside = UIBezierPath(rect: bounds)
        outside.append(pill)
        plainMask.path = outside.cgPath
        CATransaction.commit()
    }
}
#endif
