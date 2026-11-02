import AppKit
import CmuxNextDesign
import CmuxNextIcons

/// The shared notice card above the footer (BOTTOM-LEFT-CARDS K1; Lawrence
/// 2026-10-09): every message to the user in this slot (the "Did you know"
/// tip, the update status) is this card. An optional heading, an icon
/// beside the title (a small spinner while work has no measured progress),
/// one short detail of up to two lines, an optional progress bar, up to
/// two buttons (the call to action filled, the others quiet) with an
/// optional shortcut beside them, and an x. Rows a notice does not use take
/// no room. Hidden without a notice. It sits on the composer's surface
/// (`CardSurfaceView`, Leo 2026-10-13), as every sidebar card does: the
/// theme's text tint over the wallpaper, opaque under Reduce Transparency.
final class SidebarNoticeCardView: NSView {
    /// A button: the notice's id and the action's id.
    var onAction: ((String, String) -> Void)?
    var onDismiss: ((String) -> Void)?
    private(set) var notice: SidebarNoticeCard?
    let eyebrowLabel = ChromeLabel(labelWithString: "")
    let titleLabel = ChromeLabel(labelWithString: "")
    private let detailLabel = ChromeLabel(wrappingLabelWithString: "")
    private let shortcutLabel = ChromeLabel(labelWithString: "")
    /// List lines under the detail (a changelog), one label each.
    private var lineLabels: [ChromeLabel] = []
    private let icon = DecorativeImageView() // the card's title says what it is
    private let spinner = StatusIndicatorView.spinner()
    private let track = CALayer()
    private let bar = CALayer()
    private(set) var actionButtons: [SidebarUpdateButton] = []
    /// The action drawn as a switch (``SidebarNoticeCard/Action/isSwitch``), right of the buttons; nil until one shows.
    private(set) var actionSwitch: SidebarCardSwitch?
    /// The notice the card shows (or last showed, during its exit) has a switch action.
    private var hasSwitch = false
    let closeButton = SidebarIconButton(icon: .actionClose, pointSize: { 9 }, label: "")
    /// The control on the right, vertically centred in the card (``SidebarNoticeCard/trailing``):
    /// a running download's cancel.
    let trailingButton = SidebarIconButton(symbol: "xmark.circle.fill", pointSize: { SidebarNoticeCardView.trailingGlyph }, label: "")
    /// The text button that replaces the x when the notice names one (``SidebarNoticeCard/dismissTitle``).
    let dismissButton = SidebarCardTextButton()
    /// The card's surface: the composer's, opaque under Reduce Transparency.
    let surface: CardSurfaceView
    /// The lines and buttons, flipped, over the surface.
    private let content = SidebarNoticeCardContent()
    /// The notice whose `shownAction` was sent (once per notice id), and its
    /// `hiddenAction` (sent when that notice leaves the card).
    private var reportedShown: (id: String, hiddenAction: String?)?
    private var occlusionObserver: NSObjectProtocol?
    /// Shows and hides the card with its entrance and exit (``SidebarCardTransition``).
    private(set) lazy var presence = SidebarCardPresence(self, policy: motionPolicy)
    private let motionPolicy: @MainActor () -> MotionPolicy
    /// The card plays its exit: the slot keeps it in place until it has gone.
    var isLeaving: Bool { presence.isLeaving }

    /// - Parameter motionPolicy: The motion settings the card's transitions follow (`Motion.overlays.policy`).
    init(frame: NSRect = .zero, reduceTransparency: ReduceTransparency = .shared,
         motionPolicy: @escaping @MainActor () -> MotionPolicy = { Motion.overlays.policy }) {
        surface = CardSurfaceView(cornerRadius: Metrics.space3, reduceTransparency: reduceTransparency)
        self.motionPolicy = motionPolicy
        super.init(frame: frame)
        wantsLayer = true
        addSubview(surface)
        addSubview(content)
        for label in [eyebrowLabel, titleLabel, shortcutLabel] {
            label.lineBreakMode = .byTruncatingTail
            label.maximumNumberOfLines = 1
        }
        detailLabel.maximumNumberOfLines = 2
        detailLabel.lineBreakMode = .byWordWrapping
        detailLabel.truncatesLastVisibleLine = true
        detailLabel.isSelectable = false
        shortcutLabel.alignment = .right
        icon.imageScaling = .scaleProportionallyDown
        content.wantsLayer = true
        // Nothing draws past the card's rounded edge: a card laid out narrower than its rows (a sidebar laid out
        // small) drew its switch past its leading edge, alone, with no card around it (Lawrence msg 19185).
        content.layer?.masksToBounds = true
        track.cornerRadius = 1.5
        bar.cornerRadius = 1.5
        // The bar lives in the track, which clips it: the unmeasured sweep never leaves the track.
        track.masksToBounds = true
        content.layer?.addSublayer(track)
        track.addSublayer(bar)
        closeButton.takesKeyFocus = true
        closeButton.onPress = { [weak self] in self?.closePressed() }
        dismissButton.onPress = { [weak self] in if let id = self?.notice?.id { self?.onDismiss?(id) } }
        trailingButton.takesKeyFocus = true
        trailingButton.takesFirstClick = true
        trailingButton.showsLabelToolTip = true
        trailingButton.onPress = { [weak self] in
            guard let id = self?.notice?.id, let action = self?.notice?.trailing?.id else { return }
            self?.onAction?(id, action)
        }
        trailingButton.isHidden = true
        [eyebrowLabel, titleLabel, detailLabel, shortcutLabel, icon, spinner, closeButton, dismissButton, trailingButton].forEach(content.addSubview)
        trailingButton.setAccessibilityIdentifier("cmux.sidebar.notice.trailing")
        closeButton.setAccessibilityIdentifier("cmux.sidebar.notice.close")
        dismissButton.setAccessibilityIdentifier("cmux.sidebar.notice.dismiss")
        setAccessibilityElement(false)
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    nonisolated override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    /// Shows `notice`, or hides the view for nil.
    func configure(_ notice: SidebarNoticeCard?) {
        guard notice != self.notice else { return }
        let previous = self.notice
        self.notice = notice
        if let shown = reportedShown, shown.id != notice?.id {
            // The notice it reported left the card (another card took the slot, or none).
            reportedShown = nil
            if let hidden = shown.hiddenAction { onAction?(shown.id, hidden) }
        }
        let wasShowing = !isHidden && !isLeaving
        presence.setShown(notice != nil)
        guard let notice else {
            // The exit shows the last notice as it was; only its spinner stops.
            spinner.spin(false)
            return
        }
        // A new message in a card already on screen (Checking… to Up to Date) crossfades.
        if let previous, wasShowing, Self.changesMessage(from: previous, to: notice) {
            presence.transition.crossfade(content.layer)
        }
        eyebrowLabel.stringValue = notice.eyebrow ?? ""
        eyebrowLabel.isHidden = notice.eyebrow == nil
        titleLabel.stringValue = notice.title
        detailLabel.stringValue = notice.detail ?? ""
        detailLabel.isHidden = notice.detail == nil
        if previous?.lines != notice.lines {
            lineLabels.forEach { $0.removeFromSuperview() }
            lineLabels = notice.lines.prefix(Self.maxLines).map { line in
                let label = ChromeLabel(labelWithString: "• " + line)
                label.lineBreakMode = .byTruncatingTail
                label.maximumNumberOfLines = 1
                label.themedToolTip = line
                content.addSubview(label)
                return label
            }
        }
        shortcutLabel.stringValue = notice.shortcut ?? ""
        shortcutLabel.isHidden = notice.shortcut == nil || notice.actions.isEmpty
        let spins = notice.progress == .indeterminate && notice.leadingSpinner
        icon.isHidden = notice.symbol == nil || spins
        spinner.spin(spins)
        closeButton.isHidden = notice.dismissLabel == nil || notice.dismissTitle != nil
        closeButton.label = notice.dismissLabel ?? ""
        dismissButton.isHidden = notice.dismissTitle == nil
        dismissButton.configure(title: notice.dismissTitle ?? "", help: notice.dismissLabel)
        if previous?.actions != notice.actions { rebuildButtons(notice.actions) }
        trailingButton.isHidden = notice.trailing == nil
        if let trailing = notice.trailing {
            trailingButton.setSymbol(trailing.symbol)
            trailingButton.label = trailing.label
            trailingButton.setAccessibilityIdentifier("cmux.sidebar.notice.action.\(trailing.id)")
        }
        let help = [notice.title, notice.detail].compactMap { $0 }.joined(separator: ". ")
        for (button, action) in zip(actionButtons, notice.actions.filter { !$0.isSwitch }) {
            button.configure(title: action.title, enabled: true, help: help)
        }
        needsLayout = true
        applyColors()
        reportShownIfOnScreen()
    }

    /// Sends the notice's `shownAction` once it is on screen: a window that is
    /// not covered, minimized or hidden, no hidden ancestor (a collapsed
    /// sidebar shows nothing) and a real size.
    private func reportShownIfOnScreen() {
        guard let notice, let action = notice.shownAction, reportedShown?.id != notice.id,
              window?.occlusionState.contains(.visible) == true, !isHiddenOrHasHiddenAncestor, !bounds.isEmpty else { return }
        reportedShown = (notice.id, notice.hiddenAction)
        onAction?(notice.id, action)
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        reportShownIfOnScreen()
    }

    /// Right-click (cx-2lm4): the card's buttons, then its x (Dismiss, or the x's menu), as menu items.
    override func menu(for event: NSEvent) -> NSMenu? {
        guard let notice else { return nil }
        let menu = NSMenu()
        addItems(notice.actions.prefix(2), to: menu)
        if let dismiss = notice.dismissLabel {
            if !menu.items.isEmpty { menu.addItem(.separator()) }
            if notice.dismissMenu.isEmpty {
                menu.addItem(withTitle: dismiss, action: #selector(menuDismiss), keyEquivalent: "").target = self
            } else {
                addItems(notice.dismissMenu[...], to: menu)
            }
        }
        return menu.items.isEmpty ? nil : menu
    }

    /// The x's menu (the tip's Hide / Mute / Never), or nil when the x dismisses at once.
    var dismissMenu: NSMenu? {
        guard let items = notice?.dismissMenu, !items.isEmpty else { return nil }
        let menu = NSMenu()
        addItems(items[...], to: menu)
        return menu
    }

    /// The x: opens its menu under the x, or dismisses.
    private func closePressed() {
        guard let id = notice?.id else { return }
        guard let menu = dismissMenu else {
            onDismiss?(id)
            return
        }
        menu.popUp(positioning: nil, at: NSPoint(x: closeButton.frame.minX, y: closeButton.frame.maxY + 2), in: content)
    }

    private func addItems(_ actions: ArraySlice<SidebarNoticeCard.Action>, to menu: NSMenu) {
        for action in actions {
            let item = menu.addItem(withTitle: action.title, action: #selector(menuAction(_:)), keyEquivalent: "")
            (item.target, item.representedObject) = (self, action.id)
        }
    }

    @objc private func menuAction(_ item: NSMenuItem) {
        if let id = notice?.id, let action = item.representedObject as? String { onAction?(id, action) }
    }

    @objc private func menuDismiss() { if let id = notice?.id { onDismiss?(id) } }

    private func rebuildButtons(_ actions: [SidebarNoticeCard.Action]) {
        actionButtons.forEach { $0.removeFromSuperview() }
        let toggle = actions.first(where: \.isSwitch)
        if let toggle, actionSwitch == nil {
            let control = SidebarCardSwitch()
            content.addSubview(control)
            actionSwitch = control
        }
        hasSwitch = toggle != nil
        actionSwitch?.isHidden = toggle == nil
        actionSwitch?.configure(title: toggle?.title ?? "", identifier: toggle.map { "cmux.sidebar.notice.action.\($0.id)" })
        actionSwitch?.onFlip = { [weak self] in
            guard let id = self?.notice?.id, let toggle else { return }
            self?.onAction?(id, toggle.id)
        }
        actionButtons = actions.filter { !$0.isSwitch }.prefix(2).map { action in
            let button = SidebarUpdateButton()
            button.isQuiet = !action.prominent
            button.fixedStyle = .inverted
            button.setAccessibilityIdentifier("cmux.sidebar.notice.action.\(action.id)")
            button.onPress = { [weak self] in
                guard let id = self?.notice?.id else { return }
                self?.onAction?(id, action.id)
            }
            content.addSubview(button)
            return button
        }
    }

    /// Whether `old` to `new` changes what the card says (not only its progress).
    /// A download's byte count ticking in the detail is progress, not a new message: it never crossfades.
    static func changesMessage(from old: SidebarNoticeCard, to new: SidebarNoticeCard) -> Bool {
        let ticking = old.progress != nil && new.progress != nil && old.title == new.title
        return old.id != new.id || old.title != new.title || (old.detail != new.detail && !ticking) || old.symbol != new.symbol
            || old.eyebrow != new.eyebrow || old.lines != new.lines || old.actions != new.actions || old.trailing != new.trailing
            || (old.progress == nil) != (new.progress == nil)
    }

    // MARK: Geometry

    private static var padding: CGFloat { Metrics.space3 }
    private static var lineHeight: (caption: CGFloat, body: CGFloat) {
        (ceil(Typography.caption.boundingRectForFont.height), ceil(Typography.bodyEmphasized.boundingRectForFont.height))
    }
    private static let barHeight: CGFloat = 3
    /// List lines a notice shows.
    static let maxLines = 4
    private static let closeSide: CGFloat = 16
    /// The right-hand control's glyph and hit square: well above the x's, on the shared spacing tokens.
    static var trailingGlyph: CGFloat { Metrics.space6 + Metrics.space1 }
    static var trailingSide: CGFloat { Metrics.space6 + Metrics.space4 + Metrics.space2 }

    /// The card's height for `notice`: padding, the heading, the title, two
    /// detail lines, the progress bar and the button row when present.
    static func height(for notice: SidebarNoticeCard) -> CGFloat {
        let line = lineHeight
        var height = padding + line.body + padding
        if notice.eyebrow != nil { height += line.caption }
        if notice.detail != nil { height += Metrics.space1 + 2 * line.caption }
        if !notice.lines.isEmpty { height += Metrics.space1 + CGFloat(min(notice.lines.count, maxLines)) * line.caption }
        // Every loading stage keeps the bar's row (Lawrence 2026-10-20: "needs better loading
        // indicator"): Checking to Downloading to Installing never changes the card's height.
        if notice.progress != nil { height += Metrics.space2 + barHeight }
        if !notice.actions.isEmpty { height += Metrics.space2 + SidebarUpdateButton.height }
        return ceil(height)
    }

    override func layout() {
        super.layout()
        let b = bounds, pad = Self.padding, line = Self.lineHeight, close = Self.closeSide
        surface.frame = b
        surface.cornerRadius = Metrics.space3
        content.layer?.cornerRadius = Metrics.space3
        content.layer?.cornerCurve = .continuous
        content.frame = b
        eyebrowLabel.font = Typography.caption
        titleLabel.font = Typography.bodyEmphasized
        detailLabel.font = Typography.caption
        shortcutLabel.font = Typography.caption
        let dismissWidth = dismissButton.fittingWidth, dismissHeight = SidebarCardTextButton.height
        let titleY = pad + (eyebrowLabel.isHidden ? 0 : line.caption)
        dismissButton.frame = NSRect(x: b.width - pad / 2 - dismissWidth, y: titleY + (line.body - dismissHeight) / 2,
                                     width: dismissWidth, height: dismissHeight)
        let width = max(0, b.width - 2 * pad)
        // The right-hand control, vertically centred in the whole card; the text and the bar stop
        // a grid step short of it.
        let trailingSide = Self.trailingSide
        let trailingRoom = trailingButton.isHidden ? 0 : trailingSide + Metrics.space4
        trailingButton.frame = NSRect(x: b.width - pad - trailingSide, y: ((b.height - trailingSide) / 2).rounded(),
                                      width: trailingSide, height: trailingSide)
        let closeRoom = !dismissButton.isHidden ? dismissWidth + Metrics.space1 : closeButton.isHidden ? trailingRoom : close
        var y = pad
        if !eyebrowLabel.isHidden {
            eyebrowLabel.frame = NSRect(x: pad, y: y, width: max(0, width - closeRoom), height: line.caption)
            y += line.caption
        }
        let showsGlyph = !icon.isHidden || !spinner.isHidden
        let glyphSide = line.body, textX = pad + (showsGlyph ? glyphSide + Metrics.space2 : 0)
        icon.frame = NSRect(x: pad, y: y, width: glyphSide, height: glyphSide)
        spinner.frame = icon.frame
        let titleWidth = max(0, b.width - pad - textX - (eyebrowLabel.isHidden || !dismissButton.isHidden ? closeRoom : 0))
        titleLabel.frame = NSRect(x: textX, y: y, width: titleWidth, height: line.body)
        // The x centers on the first line's capitals, the heading's or else the title's (live-qa
        // 2026-10-21: centered in the padding corner it sat a point above the heading).
        let first = eyebrowLabel.isHidden ? titleLabel : eyebrowLabel
        let capMid = first.frame.minY + first.firstBaselineOffsetFromTop - (first.font?.capHeight ?? 0) / 2
        let scale = window?.backingScaleFactor ?? 2
        closeButton.frame = NSRect(x: b.width - pad / 2 - close, y: ((capMid - close / 2) * scale).rounded() / scale,
                                   width: close, height: close)
        y += line.body
        let textWidth = max(0, b.width - pad - textX - trailingRoom)
        if !detailLabel.isHidden {
            detailLabel.preferredMaxLayoutWidth = textWidth
            detailLabel.frame = NSRect(x: textX, y: y + Metrics.space1, width: textWidth, height: 2 * line.caption)
            y += Metrics.space1 + 2 * line.caption
        }
        if !lineLabels.isEmpty { y += Metrics.space1 }
        for label in lineLabels {
            label.font = Typography.caption
            label.frame = NSRect(x: textX, y: y, width: textWidth, height: line.caption)
            y += line.caption
        }
        if notice?.progress != nil {
            y += Metrics.space2
            layoutProgress(CGRect(x: textX, y: y, width: textWidth, height: Self.barHeight))
        } else {
            layoutProgress(nil)
        }
        let rowY = b.height - pad - SidebarUpdateButton.height
        var x = pad
        for button in actionButtons {
            let titleWidth = ceil((button.title as NSString).size(withAttributes: [.font: SidebarUpdateButton.font]).width)
            let buttonWidth = min(max(0, b.width - pad - x), titleWidth + 2 * Metrics.space4)
            button.frame = NSRect(x: x, y: rowY, width: buttonWidth, height: SidebarUpdateButton.height)
            x = button.frame.maxX + Metrics.space2
        }
        if let actionSwitch {
            // The switch shows whole on the button row, after the buttons, or not at all: squeezed, it drew its
            // control past its own leading edge (Lawrence msg 19185).
            let size = actionSwitch.fittingSize
            let fits = hasSwitch && b.width - pad - x >= size.width
            actionSwitch.isHidden = !fits
            actionSwitch.frame = fits ? NSRect(x: b.width - pad - size.width, y: rowY + (SidebarUpdateButton.height - size.height) / 2,
                                               width: size.width, height: size.height) : .zero
        }
        shortcutLabel.frame = NSRect(x: x, y: rowY + (SidebarUpdateButton.height - line.caption) / 2,
                                     width: max(0, b.width - pad - x), height: line.caption)
        // A window that shows after the card was filled lays it out: the hint is on screen now.
        reportShownIfOnScreen()
        presence.didLayout()
    }

    /// The bar's last measured fraction, so a new one fills toward it smoothly.
    private var shownFraction: Double?

    /// Shows the progress row in `frame` (nil hides it): a measured fraction
    /// fills smoothly from the last one; unmeasured work sweeps a short
    /// segment across the track (still under Reduce Motion: the spinner
    /// glyph alone moves then).
    private func layoutProgress(_ frame: CGRect?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        guard let frame, let progress = notice?.progress else {
            track.isHidden = true
            bar.removeAnimation(forKey: Self.sweepKey)
            shownFraction = nil
            return
        }
        track.isHidden = false
        track.frame = frame
        bar.isHidden = false
        switch progress {
        case .fraction(let value):
            bar.removeAnimation(forKey: Self.sweepKey)
            let target = CGRect(x: 0, y: 0, width: frame.width * CGFloat(min(1, max(0.03, value))), height: frame.height)
            bar.anchorPoint = .zero
            bar.position = .zero
            if let shown = shownFraction, shown != value, motionPolicy().animatesFades, !isHidden {
                // Fills toward the new value instead of jumping (a download reports often and unevenly).
                Motion.overlays.set(bar, "bounds.size.width", to: target.width, fade: .highlight)
                bar.bounds.size.height = target.height
            } else {
                bar.removeAnimation(forKey: "bounds.size.width")
                bar.frame = target
            }
            shownFraction = value
        case .indeterminate:
            shownFraction = nil
            bar.removeAnimation(forKey: "bounds.size.width")
            bar.anchorPoint = .zero
            let segment = frame.width * Self.sweepWidth
            bar.frame = CGRect(x: 0, y: 0, width: segment, height: frame.height)
            guard motionPolicy().animatesLoops else {
                bar.removeAnimation(forKey: Self.sweepKey)
                bar.isHidden = true
                return
            }
            if bar.animation(forKey: Self.sweepKey) != nil, sweptTravel == frame.width { return }
            guard let sweep = Motion.indicators.sweepAnimation(segment: segment, travel: frame.width, policy: motionPolicy()) else {
                bar.isHidden = true
                return
            }
            sweptTravel = frame.width
            bar.add(sweep, forKey: Self.sweepKey)
        }
    }

    /// The track width the running sweep crosses.
    private var sweptTravel: CGFloat = 0

    private static let sweepKey = "notice.progress.sweep"
    /// The unmeasured segment's share of the track.
    private static let sweepWidth: CGFloat = 0.32

    /// The progress row as shown, for tests: hidden, sweeping (unmeasured) or the bar's fraction of the track.
    var progressShown: ProgressShown {
        guard !track.isHidden else { return .none }
        if bar.animation(forKey: Self.sweepKey) != nil { return .sweeping }
        if notice?.progress == .indeterminate { return .still }
        return .fraction(track.bounds.width > 0 ? Double(bar.frame.width / track.bounds.width) : 0)
    }

    /// What ``progressShown`` reports.
    enum ProgressShown: Equatable {
        case none
        /// Unmeasured work with Reduce Motion (or motion off): the track alone; the spinner glyph moves.
        case still
        /// Unmeasured work: a segment sweeps across the track.
        case sweeping
        case fraction(Double)
    }

    private func applyColors() {
        performWithTheme {
            eyebrowLabel.textColor = Palette.textSecondary
            titleLabel.textColor = Palette.textPrimary
            detailLabel.textColor = Palette.textSecondary
            for label in lineLabels { label.textColor = Palette.textSecondary }
            shortcutLabel.textColor = Palette.textTertiary
            actionSwitch?.applyColors()
            icon.contentTintColor = Palette.textSecondary
            icon.image = notice?.symbol.map { NSImage.icon(symbol: $0, size: .iconRowSize(forLabelPointSize: Typography.bodyEmphasized.pointSize)) }
            track.backgroundColor = Palette.hoverFill.cgColor
            bar.backgroundColor = Palette.textSecondary.cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
        surface.needsDisplay = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyColors()
        if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) }
        occlusionObserver = window.map { window in
            // A window that comes into view (unhidden app, restored, another window moved away) shows the card now.
            NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reportShownIfOnScreen() } // main-proof: observer on queue: .main
            }
        }
        reportShownIfOnScreen()
    }

    // MARK: Tests

    /// Every line as shown, top to bottom.
    var shownText: [String] {
        [eyebrowLabel, titleLabel, detailLabel].filter { !$0.isHidden }.map(\.stringValue) + actionButtons.map(\.title)
            + (shortcutLabel.isHidden ? [] : [shortcutLabel.stringValue])
    }
}

/// The notice card's lines and buttons, flipped, over its surface.
private final class SidebarNoticeCardContent: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    nonisolated override var isFlipped: Bool { true }
}
