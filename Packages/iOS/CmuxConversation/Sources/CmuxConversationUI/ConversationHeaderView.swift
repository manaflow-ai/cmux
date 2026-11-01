#if canImport(UIKit)
import CmuxConversationCore
import CmuxConversationGeometry
import UIKit

/// Messages header: glass back capsule (with unread count), a centered
/// avatar (or group cluster) above a glass name pill, and a trailing glass
/// circle action that becomes an X in select and reply modes.
final class ConversationHeaderView: UIView {
    enum TrailingMode {
        case action
        case close
        /// Select mode ("More…"): the same X, read as Cancel.
        case cancel
    }

    let backGlass = makeGlassView(cornerRadius: 22, interactive: true, clipsContent: false)
    let backButton = UIButton(type: .system)
    private let unreadLabel = UILabel()
    private let unreadPill = UIView()
    private var avatars: [ConversationAvatarView] = []
    /// The avatar or group cluster: the details zoom out of (and back into) it.
    let avatarContainer = UIView()
    /// Group chats seat their avatar cluster on a 60 pt glass disc.
    private let clusterDisc = makeGlassView(cornerRadius: 30, clipsContent: false)
    /// Measured on iOS 26 Messages: a 32.33 pt capsule 55 pt below the safe
    /// area top, bold 17 pt name inset 13 pt, then a heavy compact chevron
    /// 5.9 pt after the text and 10.9 pt from the trailing edge.
    static let namePillHeight: CGFloat = 97.0 / 3
    let namePillGlass = makeGlassView(cornerRadius: 97.0 / 6, interactive: true, clipsContent: false)
    let nameButton = UIButton(type: .system)
    private let nameLabel = UILabel()
    /// ChatKit's title chevron: `chevron.compact.forward` at the body size,
    /// heavy, small scale, in tertiary label color.
    private let chevron = UIImageView(image: UIImage(systemName: "chevron.compact.forward", withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .heavy, scale: .small)))
    let trailingGlass = makeGlassView(cornerRadius: 22, interactive: true, clipsContent: false)
    let trailingButton = UIButton(type: .system)
    private let avatarTapButton = UIButton(type: .custom)
    let statusLabel = UILabel()
    /// iOS 27 sizes the soft top pocket from the elements inside its
    /// container: glass alone makes it the safe top + 120 pt (182 here),
    /// while a floating element (a label) ends it 60 pt below that element's
    /// top (at least the safe top + 60). Messages' pocket (its navigation
    /// bar's) ends 8 pt under the name capsule (157.33 at Large, 162.33 at
    /// AX3), so this empty label sits 52 pt above the capsule's bottom.
    private let pocketAnchor = UILabel()
    static let pocketBelowCapsule: CGFloat = 8
    static let floatingElementPocketExtent: CGFloat = 60

    var onBack: (() -> Void)?
    var onInfo: (() -> Void)?
    var onTrailing: (() -> Void)?
    var trailingSymbol = "video"
    var presentation = ConversationHeaderPresentation() {
        didSet {
            if let label = presentation.avatarAccessibilityLabel { avatarTapButton.accessibilityLabel = label }
            if let hint = presentation.avatarAccessibilityHint { avatarTapButton.accessibilityHint = hint }
        }
    }
    private(set) var trailingMode: TrailingMode = .action

    static let contentHeight: CGFloat = 92
    /// Above the name capsule (z 0), so the avatar occludes it.
    static let avatarZPosition: CGFloat = 1

    override init(frame: CGRect) {
        super.init(frame: frame)
        addSubview(backGlass)
        backGlass.contentView.addSubview(backButton)
        backButton.setImage(UIImage(systemName: "chevron.left", withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold)), for: .normal)
        backButton.tintColor = .label
        backButton.accessibilityLabel = String(localized: "conversation.header.back", defaultValue: "Back", bundle: .module)
        backButton.addAction(UIAction { [weak self] _ in self?.onBack?() }, for: .touchUpInside)
        // Dark: a near-white pill (243) under the count; light keeps the inverse.
        unreadPill.backgroundColor = UIColor.resolving { $0.userInterfaceStyle == .dark ? UIColor(white: 243.0 / 255, alpha: 1) : UIColor(white: 0.25, alpha: 1) }
        unreadLabel.font = .systemFont(ofSize: ConversationHeaderGeometry.unreadFontSize, weight: .medium)
        unreadLabel.textColor = UIColor.resolving { $0.userInterfaceStyle == .dark ? .black : .white }
        unreadLabel.textAlignment = .center
        backGlass.contentView.addSubview(unreadPill)
        unreadPill.addSubview(unreadLabel)
        unreadPill.isUserInteractionEnabled = false
        // The count is spoken as the back button's value, not as a stray "349".
        unreadPill.isAccessibilityElement = false
        unreadPill.accessibilityElementsHidden = true

        clusterDisc.isUserInteractionEnabled = false
        clusterDisc.isHidden = true
        // Messages draws the avatar over the name capsule where they overlap
        // (iOS 26.5 and 27.0). The layer order does that; the subview order
        // keeps VoiceOver reading the photo before the name.
        avatarContainer.layer.zPosition = Self.avatarZPosition
        avatarContainer.isUserInteractionEnabled = false
        // The details zoom morphs out of this view; ChatKit's avatar button
        // shadow keeps the close free of UIKit's card platter and shadow.
        let shadow = ConversationHeaderGeometry.avatarShadow
        avatarContainer.layer.shadowOpacity = shadow.opacity
        avatarContainer.layer.shadowRadius = shadow.radius
        avatarContainer.layer.shadowOffset = shadow.offset
        setAvatarShadowScale(1)
        addSubview(avatarContainer)
        avatarContainer.addSubview(clusterDisc)
        addSubview(avatarTapButton)
        avatarTapButton.addAction(UIAction { [weak self] _ in self?.onInfo?() }, for: .touchUpInside)
        avatarTapButton.accessibilityLabel = String(localized: "conversation.ax.contactPhoto", defaultValue: "Contact photo", bundle: .module)
        avatarTapButton.accessibilityHint = String(localized: "conversation.ax.contactPhoto.hint", defaultValue: "Double-tap to view details", bundle: .module)

        addSubview(namePillGlass)
        namePillGlass.contentView.addSubview(nameButton)
        nameLabel.font = Self.nameFont
        nameLabel.textColor = .label
        namePillGlass.contentView.addSubview(nameLabel)
        // The pill's button speaks the name; the label is its visual only.
        nameLabel.isAccessibilityElement = false
        chevron.tintColor = .tertiaryLabel
        chevron.contentMode = .center
        chevron.isAccessibilityElement = false
        namePillGlass.contentView.addSubview(chevron)
        nameButton.addAction(UIAction { [weak self] _ in self?.onInfo?() }, for: .touchUpInside)
        nameButton.accessibilityIdentifier = "conversation.header.name"

        // The buttons sit on the navigation bar's layout margin (16 or 20 pt).
        preservesSuperviewLayoutMargins = true
        addSubview(trailingGlass)
        trailingGlass.contentView.addSubview(trailingButton)
        trailingButton.tintColor = .label
        trailingButton.addAction(UIAction { [weak self] _ in self?.onTrailing?() }, for: .touchUpInside)
        trailingButton.accessibilityIdentifier = "conversation.header.trailing"
        setTrailingMode(.action, animated: false)

        statusLabel.font = .systemFont(ofSize: 11, weight: .medium)
        statusLabel.textColor = .secondaryLabel
        statusLabel.textAlignment = .center
        statusLabel.alpha = 0
        addSubview(statusLabel)
        if #available(iOS 27.0, *) {
            pocketAnchor.isAccessibilityElement = false
            pocketAnchor.isUserInteractionEnabled = false
            insertSubview(pocketAnchor, at: 0)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(info: ConversationInfo, meID: String?, unreadCount: Int) {
        nameLabel.text = info.title
        nameButton.accessibilityLabel = info.title
        let others = info.participants.filter { $0.id != meID }
        let shown = info.kind == .group ? Array(others.prefix(3)) : Array(others.prefix(1))
        avatars.forEach { $0.removeFromSuperview() }
        avatars = shown.map { participant in
            let view = ConversationAvatarView()
            view.configure(initials: participant.initials, colorHex: nil)
            view.layer.borderWidth = info.kind == .group ? ConversationHeaderGeometry.groupClusterRingWidth : 0
            avatarContainer.addSubview(view)
            return view
        }
        clusterDisc.isHidden = info.kind != .group
        unreadLabel.text = unreadCount > 0 ? "\(unreadCount)" : nil
        unreadPill.isHidden = unreadCount <= 0
        backButton.accessibilityValue = unreadCount > 0
            ? String(format: String(localized: "conversation.ax.backUnread", defaultValue: "%d unread", bundle: .module), unreadCount)
            : nil
        setNeedsLayout()
    }

    func setConnectionStatus(_ text: String?) {
        statusLabel.text = text
        UIView.animate(withDuration: 0.25) { self.statusLabel.alpha = text == nil ? 0 : 1 }
    }

    func setTrailingMode(_ mode: TrailingMode, animated: Bool, delay: TimeInterval = 0, duration: TimeInterval = 0.2) {
        trailingMode = mode
        let isX = mode != .action
        let symbol = isX ? "xmark" : trailingSymbol
        let apply = {
            // Both glyphs are a bar button's default symbol (body, 17 pt
            // regular): the video 26.7 x 17.7 pt ink, Cancel's xmark 17.33 x 15.33 pt.
            self.trailingButton.setImage(UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .regular)), for: .normal)
            self.trailingButton.accessibilityLabel = mode == .cancel
                ? String(localized: "conversation.select.cancel", defaultValue: "Cancel", bundle: .module)
                : mode == .close
                ? String(localized: "conversation.header.close", defaultValue: "Close", bundle: .module)
                : self.presentation.actionAccessibilityLabel ?? (self.trailingSymbol.hasPrefix("video")
                    ? String(localized: "conversation.ax.facetime", defaultValue: "FaceTime", bundle: .module)
                    : String(localized: "conversation.header.action", defaultValue: "Call", bundle: .module))
        }
        guard animated else { apply(); return }
        guard delay > 0 else {
            UIView.transition(with: trailingButton, duration: duration, options: .transitionCrossDissolve, animations: apply)
            return
        }
        // A delayed change fades the old glyph out and the new one in.
        UIView.animate(withDuration: 0.05, delay: delay, options: [.beginFromCurrentState]) {
            self.trailingButton.alpha = 0
        } completion: { _ in
            guard self.trailingMode == mode else { return }
            apply()
            UIView.animate(withDuration: duration) { self.trailingButton.alpha = 1 }
        }
    }

    /// The name follows Dynamic Type between Large and XXL and holds outside
    /// that range (`ConversationHeaderGeometry.namePointSize`). Bold, as
    /// measured in Messages' name capsule.
    static var nameFont: UIFont {
        let headline = ConversationTheme.scaled(17, .headline)
        return .systemFont(ofSize: ConversationHeaderGeometry.namePointSize(scaled: headline), weight: .bold)
    }
    static let largeNameFont = UIFont.systemFont(ofSize: 17, weight: .bold)

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if traitCollection.changesTextMetrics(from: previousTraitCollection) {
            nameLabel.font = Self.nameFont
            setNeedsLayout()
        }
        if traitCollection.verticalSizeClass != previousTraitCollection?.verticalSizeClass { setNeedsLayout() }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let top = safeAreaInsets.top
        let margin = ConversationHeaderGeometry.sideMargin(layoutMargin: layoutMargins.left)
        let hasUnread = !unreadPill.isHidden
        unreadLabel.sizeToFit()
        let unreadWidth = hasUnread ? unreadLabel.bounds.width : nil
        let backWidth = ConversationHeaderGeometry.backWidth(unreadTextWidth: unreadWidth)
        backGlass.frame = CGRect(x: margin, y: top, width: backWidth, height: 44)
        let chevronShift = hasUnread ? ConversationHeaderGeometry.unreadChevronShift : 0
        backButton.frame = CGRect(x: 2 + chevronShift, y: ConversationHeaderGeometry.backChevronDrop, width: 40, height: 44)
        if let unreadWidth {
            unreadPill.frame = ConversationHeaderGeometry.unreadPillFrame(textWidth: unreadWidth)
            unreadPill.layer.cornerRadius = unreadPill.bounds.height / 2
            unreadLabel.frame = unreadPill.bounds
        }

        trailingGlass.frame = CGRect(x: bounds.width - ConversationHeaderGeometry.sideMargin(layoutMargin: layoutMargins.right) - 44, y: top, width: 44, height: 44)
        trailingButton.frame = trailingGlass.bounds

        if isCompact {
            layoutCompact(margin: margin)
            return
        }
        restorePillGlass()
        setAvatarShadowScale(1)
        let centerX = bounds.midX
        avatarContainer.frame = CGRect(x: centerX - 30, y: top, width: 60, height: 60)
        if avatars.count <= 1 {
            avatars.first?.frame = avatarContainer.bounds
        } else {
            // Cluster: the first large, the rest small and offset.
            clusterDisc.frame = avatarContainer.bounds
            for (avatar, slot) in zip(avatars, ConversationHeaderGeometry.groupClusterSlots) { avatar.frame = slot }
        }
        let clusterBottom = avatars.isEmpty ? top + 60 : top + (avatars.map(\.frame.maxY).max() ?? 60)
        avatarTapButton.frame = CGRect(x: centerX - 40, y: top, width: 80, height: clusterBottom - top)

        nameLabel.sizeToFit()
        let chevronInk: CGFloat = 4.7
        let pillWidth2 = min(bounds.width - 2 * (margin + 60), 13 + nameLabel.bounds.width + 5.9 + chevronInk + 10.9)
        // 32.33 pt at Large; grows with the (capped) Dynamic Type name.
        let pillHeight = Self.namePillHeight + max(0, ceil(nameLabel.font.lineHeight) - ceil(Self.largeNameFont.lineHeight))
        namePillGlass.layer.cornerRadius = pillHeight / 2
        let pillY = max(top + 55, clusterBottom - 5)
        namePillGlass.frame = CGRect(x: centerX - pillWidth2 / 2, y: pillY, width: pillWidth2, height: pillHeight)
        nameLabel.frame = CGRect(x: 13, y: 0, width: pillWidth2 - 13 - 5.9 - chevronInk - 10.9, height: pillHeight)
        let chevronSize = chevron.image?.size ?? CGSize(width: 8, height: 15)
        chevron.frame = CGRect(x: pillWidth2 - 10.9 - chevronInk / 2 - chevronSize.width / 2, y: (pillHeight - chevronSize.height) / 2, width: chevronSize.width, height: chevronSize.height)
        nameButton.frame = namePillGlass.bounds
        statusLabel.frame = CGRect(x: 0, y: namePillGlass.frame.maxY + 2, width: bounds.width, height: 14)
        let anchorTop = namePillGlass.frame.maxY + Self.pocketBelowCapsule - Self.floatingElementPocketExtent
        pocketAnchor.frame = CGRect(x: centerX, y: anchorTop, width: 1, height: 1)
    }

    /// Landscape iPhone: Messages' compact bar (see
    /// `ConversationHeaderGeometry.compactLayout`).
    var isCompact: Bool { traitCollection.verticalSizeClass == .compact && traitCollection.userInterfaceIdiom == .phone }

    /// The header's height below the safe top: the 92 pt stack, or the
    /// compact bar's bottom.
    var heightBelowSafeTop: CGFloat {
        guard isCompact else { return Self.contentHeight }
        let bar = ConversationHeaderGeometry.compactBarTop
        return max(safeAreaInsets.top, bar) + ConversationHeaderGeometry.compactBarHeight - safeAreaInsets.top
    }

    private var avatarShadowScale: CGFloat = 0

    /// ChatKit's avatar shadow path, scaled with the compact bar's 44 pt avatar.
    private func setAvatarShadowScale(_ scale: CGFloat) {
        guard avatarShadowScale != scale else { return }
        avatarShadowScale = scale
        let diameter = ConversationHeaderGeometry.avatarShadow.pathDiameter * scale
        avatarContainer.layer.shadowPath = UIBezierPath(ovalIn: CGRect(x: 0, y: 0, width: diameter, height: diameter)).cgPath
    }

    private var pillGlassEffect: UIVisualEffect?
    private var pillGlassCleared = false

    /// The compact bar shows the name without its capsule.
    private func clearPillGlass() {
        guard !pillGlassCleared else { return }
        pillGlassCleared = true
        pillGlassEffect = namePillGlass.effect
        namePillGlass.effect = nil
    }

    private func restorePillGlass() {
        guard pillGlassCleared else { return }
        pillGlassCleared = false
        namePillGlass.effect = pillGlassEffect
    }

    private func layoutCompact(margin: CGFloat) {
        clearPillGlass()
        let chevronSize = chevron.image?.size ?? CGSize(width: 8, height: 15)
        nameLabel.sizeToFit()
        let maxName = max(0, bounds.width - 2 * (margin + 44 + 8) - ConversationHeaderGeometry.compactAvatarSize - 24 - chevronSize.width)
        let nameSize = CGSize(width: min(nameLabel.bounds.width, maxName), height: ceil(nameLabel.font.lineHeight))
        let layout = ConversationHeaderGeometry.compactLayout(width: bounds.width, safeTop: safeAreaInsets.top, nameSize: nameSize, chevronSize: chevronSize)
        backGlass.frame.origin.y = layout.barTop
        trailingGlass.frame.origin.y = layout.barTop
        avatarContainer.frame = layout.avatar
        let scale = layout.avatar.width / 60
        setAvatarShadowScale(scale)
        if avatars.count <= 1 {
            avatars.first?.frame = avatarContainer.bounds
        } else {
            clusterDisc.frame = avatarContainer.bounds
            for (avatar, slot) in zip(avatars, ConversationHeaderGeometry.groupClusterSlots(in: avatarContainer.bounds)) { avatar.frame = slot }
        }
        avatarTapButton.frame = layout.avatar
        let pill = CGRect(x: layout.name.minX - ConversationHeaderGeometry.compactNameGap, y: layout.barTop,
                          width: layout.chevron.maxX + ConversationHeaderGeometry.compactTrailingPadding - layout.name.minX + ConversationHeaderGeometry.compactNameGap,
                          height: ConversationHeaderGeometry.compactAvatarSize)
        namePillGlass.frame = pill
        nameLabel.frame = layout.name.offsetBy(dx: -pill.minX, dy: -pill.minY)
        chevron.frame = layout.chevron.offsetBy(dx: -pill.minX, dy: -pill.minY)
        nameButton.frame = namePillGlass.bounds
        statusLabel.frame = CGRect(x: 0, y: layout.avatar.maxY + 2, width: bounds.width, height: 14)
        let anchorTop = layout.barTop + layout.barHeight + Self.pocketBelowCapsule - Self.floatingElementPocketExtent
        pocketAnchor.frame = CGRect(x: bounds.midX, y: anchorTop, width: 1, height: 1)
    }

    /// Select mode hides the back button; the trailing X (Cancel) is the way out.
    func setBackHidden(_ hidden: Bool, animated: Bool, delay: TimeInterval = 0, duration: TimeInterval = 0.2) {
        let apply = { self.backGlass.alpha = hidden ? 0 : 1 }
        backGlass.isUserInteractionEnabled = !hidden
        backGlass.accessibilityElementsHidden = hidden
        guard animated else { apply(); return }
        UIView.animate(withDuration: duration, delay: delay, options: [.beginFromCurrentState], animations: apply)
    }

    /// The details zoom out of the avatar (Messages' zoom source is its
    /// CKAvatarButton); UIKit hides it while the details cover it.
    var zoomSourceView: UIView { avatarContainer }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        // Pass touches through the empty header area to the transcript.
        let view = super.hitTest(point, with: event)
        return view === self ? nil : view
    }
}
/// Messages' top scroll edge: the transcript washes out toward the
/// background under the header without blurring. Measured on iOS 26
/// Messages: a flat 85.5% wash (60% in dark mode) down to 74 pt above the
/// header's bottom, then an S-shaped ramp that clears 46 pt below it. The
/// system soft edge effect blurs the whole header height instead, so this
/// replaces it.
///
/// Over a conversation background there is no single color to wash toward
/// (gradients, animated looks, photos), so the transcript is masked with the
/// same ramp instead (`TranscriptCollectionView.topFadeHeaderBottom`): its
/// content fades out and the background itself shows under the header.
final class ConversationTopEdgeFade: UIView {
    static let extent = ConversationTopEdgeGeometry.extent

    private let gradient = CAGradientLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        layer.addSublayer(gradient)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        gradient.frame = bounds
        guard bounds.height > 0 else { return }
        let color = ConversationTheme.background.resolvedColor(with: traitCollection)
        let ramp = ConversationTopEdgeGeometry.ramp(height: bounds.height, headerBottom: bounds.height - Self.extent, dark: traitCollection.userInterfaceStyle == .dark)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradient.colors = ramp.map { color.withAlphaComponent($0.wash).cgColor }
        gradient.locations = ramp.map { NSNumber(value: Double($0.location)) }
        CATransaction.commit()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        setNeedsLayout()
    }
}
#endif
