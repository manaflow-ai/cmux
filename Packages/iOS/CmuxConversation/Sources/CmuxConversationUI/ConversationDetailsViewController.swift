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
    private let avatarImage: UIImage?
    let infoPage: ConversationDetailsInfoPage
    private var backgroundsPage: ConversationDetailsBackgroundsPage?

    /// Messages' backdrop: the transcript blurred at radius 16 under a 60 %
    /// wash of the background color (`ConversationVeilBlur.details`).
    private let blur = UIVisualEffectView(effect: nil)
    private var blurAnimator: UIViewPropertyAnimator?
    private let wash = UIView()
    private let pages = UIScrollView()
    private let header = ConversationDetailsHeaderView()
    let tabBar: ConversationDetailsTabBar?

    /// Opens the background editor for a category (the Backgrounds page).
    var onEditBackground: ((ConversationBackground.Kind?) -> Void)?
    var onClose: (() -> Void)?

    var background: ConversationBackground? {
        didSet { backgroundsPage?.current = background }
    }

    init?(store: ConversationStore, showsBackgrounds: Bool, avatarImage: UIImage? = nil) {
        guard let info = store.info else { return nil }
        self.store = store
        self.info = info
        meID = store.meID
        self.avatarImage = avatarImage
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
        blur.frame = view.bounds
        blur.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(blur)
        wash.frame = view.bounds
        wash.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        wash.backgroundColor = UIColor {
            let veil = ConversationVeilBlur.details(dark: $0.userInterfaceStyle == .dark)
            return UIColor(white: veil.washWhite, alpha: veil.washAlpha)
        }
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

        header.configure(info: info, meID: meID, avatarImage: avatarImage)
        view.addSubview(header)
        if let tabBar {
            tabBar.onSelect = { [weak self] index in self?.showPage(index, animated: true) }
            view.addSubview(tabBar)
        }
        // Content under the collapsed header blurs out with UIKit's scroll
        // edge effect (Messages' details: ScrollEdgeEffectView, soft).
        if #available(iOS 26.0, *) {
            // The pocket spans the header and the tabs down to where the
            // content starts, as Messages' DetailsHeaderContainer (263.67 pt
            // at rest and 166.44 collapsed without tabs).
            let headerInteraction = UIScrollEdgeElementContainerInteraction()
            headerInteraction.scrollView = infoPage.table
            headerInteraction.edge = .top
            header.addInteraction(headerInteraction)
            edgeInteractions = [headerInteraction]
            if let tabBar {
                let tabsInteraction = UIScrollEdgeElementContainerInteraction()
                tabsInteraction.scrollView = infoPage.table
                tabsInteraction.edge = .top
                tabBar.addInteraction(tabsInteraction)
                edgeInteractions.append(tabsInteraction)
            }
            // The page scroller has no edges of its own (Messages' page
            // view controller); each page's scroll view draws them.
            for edge in [pages.topEdgeEffect, pages.bottomEdgeEffect, pages.leftEdgeEffect, pages.rightEdgeEffect] { edge.isHidden = true }
            infoPage.table.topEdgeEffect.style = Self.edgeStyle
            backgroundsPage?.scroll.topEdgeEffect.style = Self.edgeStyle
        }

        // The back button is the navigation bar's own item, as in Messages'
        // CommunicationDetails: UIKit's zoom then carries the bar level into
        // the conversation's header on close (iOS 26.5, 60 fps: the button
        // slides right at a constant y), where a glass view of our own drops
        // 31 pt in the first frames as the content shrinks.
        let backItem = UIBarButtonItem(image: UIImage(systemName: "chevron.backward"), primaryAction: UIAction { [weak self] _ in self?.close() })
        backItem.accessibilityLabel = String(localized: "conversation.header.back", defaultValue: "Back", bundle: .module)
        backItem.accessibilityIdentifier = "conversation.details.back"
        backItem.tintColor = .label
        navigationItem.leftBarButtonItem = backItem
        let appearance = UINavigationBarAppearance()
        appearance.configureWithTransparentBackground()
        navigationItem.standardAppearance = appearance
        navigationItem.scrollEdgeAppearance = appearance
        accessibilityElementsOrder()
    }

    private func accessibilityElementsOrder() {
        var elements: [Any] = [header]
        if let tabBar { elements.append(tabBar) }
        elements.append(pages)
        view.accessibilityElements = elements
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        header.updateFonts()
        applyBlur()
    }

    /// Messages' close leaves no frosted card behind: its backdrop is gone
    /// from the first frame of the zoom back into the avatar, so the transcript
    /// shows sharp around the shrinking content (iPhone 17 Pro Max, iOS 26.5,
    /// 60 fps: the composer and bubbles beside the content are crisp 33 ms in).
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        guard animated, isBeingDismissed || navigationController?.isBeingDismissed == true else { return }
        wash.alpha = 0
        blurAnimator?.stopAnimation(true)
        blurAnimator = nil
        blur.effect = nil
        guard let coordinator = transitionCoordinator else { return }
        coordinator.animate(alongsideTransition: nil, completion: { [weak self] context in
            // A swipe that gives up on closing leaves the details open.
            guard let self, context.isCancelled else { return }
            self.wash.alpha = 1
            self.blur.effect = nil
            self.applyBlur()
        })
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        UIAccessibility.post(notification: .screenChanged, argument: header.titleLabel)
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if traitCollection.changesTextMetrics(from: previousTraitCollection) {
            header.updateFonts()
            view.setNeedsLayout()
        }
        if previousTraitCollection?.userInterfaceStyle != traitCollection.userInterfaceStyle {
            blurAnimator?.stopAnimation(true)
            blurAnimator = nil
            blur.effect = nil
            applyBlur()
        }
    }

    /// UIKit has no public pure blur; a paused animator holds the
    /// ultra-thin material at the share that matches Messages' radius 16.
    private func applyBlur() {
        guard blurAnimator == nil else { return }
        let veil = ConversationVeilBlur.details(dark: traitCollection.userInterfaceStyle == .dark)
        let animator = UIViewPropertyAnimator(duration: 1, curve: .linear)
        animator.addAnimations { [blur] in blur.effect = UIBlurEffect(style: .systemUltraThinMaterial) }
        animator.pausesOnCompletion = true
        animator.fractionComplete = veil.materialShare
        blurAnimator = animator
    }

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
        let margin = ConversationHeaderGeometry.sideMargin(layoutMargin: view.layoutMargins.left)
        let rest = headerLayout(offset: 0)
        infoPage.setSideMargin(margin)
        infoPage.setHeaderHeight(rest.height, bottomInset: view.safeAreaInsets.bottom)
        backgroundsPage?.setHeaderHeight(rest.height, bottomInset: view.safeAreaInsets.bottom)
        layoutHeader()
    }

    private var safeTop: CGFloat { navigationController?.view.safeAreaInsets.top ?? view.safeAreaInsets.top }

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

    /// The header for a content offset, at the current text size: the title
    /// wraps and the quick actions grow with Dynamic Type.
    private func headerLayout(offset: CGFloat) -> ConversationDetailsHeaderLayout {
        let width = view.bounds.width
        return ConversationDetailsHeaderGeometry.layout(
            width: width, safeTop: safeTop, offset: offset, showsTabs: tabBar != nil, isGroup: isGroup,
            titleHeight: header.titleHeight(width: width),
            quickActionSize: ConversationDetailsHeaderView.quickActionSize(for: traitCollection),
            tabBarHeight: tabBar?.barHeight ?? ConversationDetailsHeaderGeometry.tabBarHeight
        )
    }

    private func layoutHeader() {
        let bounds = view.bounds
        guard bounds.width > 0 else { return }
        let layout = headerLayout(offset: currentOffset)
        header.frame = CGRect(x: 0, y: 0, width: bounds.width, height: tabBar == nil ? layout.height : layout.tabBar.maxY)
        header.apply(layout)
        if let tabBar {
            // The bar reaches down to where the content starts: the scroll
            // edge pocket ends there, as Messages' header container does.
            tabBar.frame = CGRect(x: layout.tabBar.minX, y: layout.tabBar.minY, width: layout.tabBar.width, height: layout.tabBar.height + ConversationDetailsHeaderGeometry.sectionGap)
            tabBar.followPages(pageFraction)
        }

    }

    // MARK: Pages

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard scrollView === pages else { return }
        layoutHeader()
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        guard scrollView === pages else { return }
        pageDidSettle(Int(round(pageFraction)))
    }

    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        guard scrollView === pages else { return }
        pageDidSettle(Int(round(pageFraction)))
    }

    private var edgeInteractions: [AnyObject] = []

    /// iOS 26 Messages blurs softly (variable blur); iOS 27 draws a hard
    /// pocket with a hairline at the header's bottom.
    @available(iOS 26.0, *)
    static var edgeStyle: UIScrollEdgeEffect.Style {
        if #available(iOS 27.0, *) { return .hard }
        return .soft
    }


    private func pageDidSettle(_ index: Int) {
        tabBar?.selectedIndex = index
        if #available(iOS 26.0, *) {
            for case let interaction as UIScrollEdgeElementContainerInteraction in edgeInteractions {
                interaction.scrollView = index == 0 ? infoPage.table : backgroundsPage?.scroll
            }
        }
    }

    func showPage(_ index: Int, animated: Bool) {
        tabBar?.select(index, animated: animated)
        pages.setContentOffset(CGPoint(x: CGFloat(index) * pages.bounds.width, y: 0), animated: animated)
        UIAccessibility.post(notification: .layoutChanged, argument: index == 0 ? infoPage.table : backgroundsPage?.scroll)
    }

    // MARK: Store

    func storeDidChange(_ change: ConversationStoreChange) {
        if let info = store.info, info != self.info {
            self.info = info
            header.configure(info: info, meID: meID, avatarImage: avatarImage)
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
        titleLabel.font = ConversationDetailsHeaderView.titleFont(for: traitCollection)
        titleLabel.textAlignment = .center
        titleLabel.textColor = .label
        // Messages wraps the title (two lines from AX2) rather than shrinking it.
        titleLabel.numberOfLines = 2
        titleLabel.lineBreakMode = .byTruncatingTail
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

    /// Messages' `.title.bold()`: SF 28 bold at Large (ink "+1 (888)
    /// 555-1212" 245.67 pt), 48 at AX3.
    static func titleFont(for traits: UITraitCollection) -> UIFont {
        let base = UIFontDescriptor.preferredFontDescriptor(withTextStyle: .title1, compatibleWith: traits)
        let bold = base.withSymbolicTraits(.traitBold) ?? base
        return UIFont(descriptor: bold, size: 0)
    }

    /// The circle's side for the text size (48 at Large, 73 at AX3).
    static func quickActionSize(for traits: UITraitCollection) -> CGFloat {
        let order: [UIContentSizeCategory] = [
            .extraSmall, .small, .medium, .large, .extraLarge, .extraExtraLarge, .extraExtraExtraLarge,
            .accessibilityMedium, .accessibilityLarge, .accessibilityExtraLarge, .accessibilityExtraExtraLarge, .accessibilityExtraExtraExtraLarge,
        ]
        let index = order.firstIndex(of: traits.preferredContentSizeCategory) ?? 3
        return ConversationDetailsHeaderGeometry.quickActionSize(contentSizeIndex: index)
    }

    func updateFonts() {
        titleLabel.font = Self.titleFont(for: traitCollection)
    }

    /// The title's width: the header's, less 16 pt a side.
    private static func titleWidth(in width: CGFloat) -> CGFloat { width - 32 }

    /// The title's line box at its resting scale (one or two lines).
    func titleHeight(width: CGFloat) -> CGFloat {
        let fitted = titleLabel.sizeThatFits(CGSize(width: Self.titleWidth(in: width), height: .greatestFiniteMagnitude)).height
        return fitted > 0 ? fitted : ConversationDetailsHeaderGeometry.titleHeight
    }

    func configure(info: ConversationInfo, meID: String?, avatarImage: UIImage? = nil) {
        titleLabel.text = info.title
        let others = info.participants.filter { $0.id != meID }
        let shown = info.kind == .group ? Array(others.prefix(3)) : Array(others.prefix(1))
        avatars.forEach { $0.removeFromSuperview() }
        avatars = shown.map { participant in
            let view = ConversationAvatarView()
            view.configure(initials: participant.initials, colorHex: nil, image: avatarImage)
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
            clusterDisc.frame = square
            clusterDisc.layer.cornerRadius = square.width / 2
            for (avatar, slot) in zip(avatars, ConversationHeaderGeometry.groupClusterSlots(in: square)) { avatar.frame = slot }
        }
        titleLabel.transform = .identity
        titleLabel.bounds = CGRect(x: 0, y: 0, width: Self.titleWidth(in: bounds.width), height: titleHeight(width: bounds.width))
        titleLabel.center = CGPoint(x: bounds.midX, y: layout.titleTop)
        titleLabel.transform = CGAffineTransform(scaleX: layout.titleScale, y: layout.titleScale)
        actions.frame = layout.quickActions
        for button in actionButtons { button.layer.cornerRadius = layout.quickActions.height / 2 }
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
    private(set) var selection: CGFloat = 0 { didSet { setNeedsLayout() } }
    /// How far a touch has lifted the capsule (0 at rest).
    private var lift: CGFloat = 0 { didSet { setNeedsLayout() } }
    private var link: CADisplayLink?
    private var selectionMove: (from: CGFloat, to: CGFloat, start: CFTimeInterval)?
    private var liftMove: (from: CGFloat, to: CGFloat, start: CFTimeInterval, spring: SendMenuGeometry.Spring)?
    var selectedIndex = 0 {
        didSet {
            for (index, button) in buttons.enumerated() {
                button.accessibilityTraits = index == selectedIndex ? [.button, .selected] : .button
            }
        }
    }

    /// Messages' labels: the subheadline style, regular and bold (15 pt at
    /// Large, 49 at AX5; iOS 26.5).
    private var font: UIFont { UIFont.preferredFont(forTextStyle: .subheadline, compatibleWith: traitCollection) }
    private var selectedFont: UIFont {
        let descriptor = UIFontDescriptor.preferredFontDescriptor(withTextStyle: .subheadline, compatibleWith: traitCollection)
        return UIFont(descriptor: descriptor.withSymbolicTraits(.traitBold) ?? descriptor, size: 0)
    }
    /// Each tab is its regular-weight title plus 14 pt a side ("Info" is
    /// 25.79 + 28 = 53.79 pt wide in Messages).
    static let padding: CGFloat = 14
    private var capsuleHeight: CGFloat { ConversationDetailsTabGeometry.capsuleHeight(lineHeight: font.lineHeight) }
    /// The bar's height at the current text size (34 pt at Large).
    var barHeight: CGFloat { ConversationDetailsTabGeometry.barHeight(capsuleHeight: capsuleHeight, scale: traitCollection.displayScale) }

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
            plain.font = font
            plain.textColor = .secondaryLabel
            plain.textAlignment = .center
            plainLayer.addSubview(plain)
            plainLabels.append(plain)
            let bold = UILabel()
            bold.text = title
            bold.font = selectedFont
            bold.textColor = .label
            bold.textAlignment = .center
            boldLayer.addSubview(bold)
            boldLabels.append(bold)
            let button = UIButton(type: .custom)
            button.accessibilityLabel = title
            button.accessibilityIdentifier = "conversation.details.tab.\(index)"
            button.addAction(UIAction { [weak self] _ in self?.onSelect?(index) }, for: .touchUpInside)
            button.addAction(UIAction { [weak self] _ in self?.moveLift(to: 1, spring: ConversationDetailsTabGeometry.liftSpring) }, for: .touchDown)
            button.addAction(UIAction { [weak self] _ in self?.moveLift(to: 0, spring: ConversationDetailsTabGeometry.selectionSpring) }, for: [.touchUpOutside, .touchCancel])
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
        let font = font
        let widths = titles.map { ($0 as NSString).size(withAttributes: [.font: font]).width + 2 * Self.padding }
        // Centered; at the largest sizes the two tabs fill the width and
        // start at its edge rather than past it.
        var x = max(0, (bounds.width - widths.reduce(0, +)) / 2)
        let y: CGFloat = 0
        return widths.map { width in
            defer { x += width }
            return CGRect(x: x, y: y, width: width, height: capsuleHeight)
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
        let capsuleFrame = ConversationDetailsTabGeometry.capsule(SendMenuGeometry.interpolate(first, last, selection), lift: lift)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        capsule.frame = capsuleFrame
        let pill = UIBezierPath(roundedRect: capsuleFrame, cornerRadius: capsuleFrame.height / 2)
        boldMask.path = pill.cgPath
        let outside = UIBezierPath(rect: bounds.insetBy(dx: 0, dy: -20))
        outside.append(pill)
        plainMask.path = outside.cgPath
        CATransaction.commit()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { updateFonts() }
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if traitCollection.changesTextMetrics(from: previousTraitCollection) { updateFonts() }
    }

    /// The labels follow Dynamic Type.
    func updateFonts() {
        let font = font, selectedFont = selectedFont
        for label in plainLabels { label.font = font }
        for label in boldLabels { label.font = selectedFont }
        setNeedsLayout()
    }

    // MARK: Motion

    /// Follows a page swipe, unless a tap's spring is running.
    func followPages(_ fraction: CGFloat) {
        guard selectionMove == nil else { return }
        selection = fraction
    }

    /// A tap: the capsule springs to the tab (Messages: damping 0.85,
    /// response 0.435 s) and settles from its lift on the same spring.
    func select(_ index: Int, animated: Bool) {
        selectedIndex = index
        guard animated, window != nil else {
            selectionMove = nil
            liftMove = nil
            selection = CGFloat(index)
            lift = 0
            return
        }
        selectionMove = (selection, CGFloat(index), CACurrentMediaTime())
        moveLift(to: 0, spring: ConversationDetailsTabGeometry.selectionSpring)
    }

    private func moveLift(to target: CGFloat, spring: SendMenuGeometry.Spring) {
        liftMove = (lift, target, CACurrentMediaTime(), spring)
        startLink()
    }

    private func startLink() {
        guard link == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(step(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func step(_ link: CADisplayLink) {
        let now = link.targetTimestamp
        var running = false
        if let move = selectionMove {
            let spring = ConversationDetailsTabGeometry.selectionSpring
            let t = now - move.start
            selection = move.from + (move.to - move.from) * spring.progress(at: t)
            if t >= spring.settlingDuration * 2 {
                selection = move.to
                selectionMove = nil
            } else {
                running = true
            }
        }
        if let move = liftMove {
            let t = now - move.start
            lift = move.from + (move.to - move.from) * move.spring.progress(at: t)
            if t >= move.spring.settlingDuration * 2 {
                lift = move.to
                liftMove = nil
            } else {
                running = true
            }
        }
        if !running {
            link.invalidate()
            self.link = nil
        }
    }

    override func willMove(toWindow newWindow: UIWindow?) {
        super.willMove(toWindow: newWindow)
        if newWindow == nil {
            link?.invalidate()
            link = nil
        }
    }
}
#endif
