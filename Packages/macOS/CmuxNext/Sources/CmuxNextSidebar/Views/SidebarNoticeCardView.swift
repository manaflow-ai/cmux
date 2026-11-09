import AppKit
import CmuxNextDesign
import CmuxNextIcons

/// The shared notice card above the footer (BOTTOM-LEFT-CARDS K1; Lawrence
/// 2026-10-09): every message to the user in this slot (the "Did you know"
/// tip, the update status) is this card. An optional icon on its own row
/// above the title (a small spinner while work has no measured progress),
/// an optional heading, a detail, an optional progress bar, up to two
/// buttons (the call to action filled, the others quiet) with an optional
/// shortcut beside them, and an x. Every row starts at the card's padding,
/// the icon's too; the title, detail and list lines wrap in full and a
/// button that does not fit starts a new row, so the card is as tall as
/// what it says (``measureFrames(for:width:dismissWidth:placement:measuring:)``). Rows a
/// notice does not use take no room. Hidden without a notice. It sits on the composer's surface
/// (`CardSurfaceView`, Leo 2026-10-13), as every sidebar card does, its
/// veil in the theme's glass tint (``CardSurfaceView/takesThemeTint``, as
/// the Updated card's): opaque under Reduce Transparency. Leo 2026-11-03,
/// on the Downloading Update card: "will this be themeed properly?"
final class SidebarNoticeCardView: NSView {
    /// A button: the notice's id and the action's id.
    var onAction: ((String, String) -> Void)?
    var onDismiss: ((String) -> Void)?
    private(set) var notice: SidebarNoticeCard?
    /// The last notice shown: the card lays it out during its exit, when ``notice`` is nil.
    private var laidOut: SidebarNoticeCard?
    let eyebrowLabel = ChromeLabel(labelWithString: "")
    /// The title and detail wrap in full at the card's width (Leo 2026-11-05: the hang-reports card's detail ended in "…").
    let titleLabel = SidebarNoticeCardView.wrappingLabel()
    private let detailLabel = SidebarNoticeCardView.wrappingLabel()
    private let shortcutLabel = ChromeLabel(labelWithString: "")
    /// List lines under the detail (a changelog), one label each.
    private var lineLabels: [ChromeLabel] = []
    private let icon = DecorativeImageView() // the card's title says what it is
    private let spinner = StatusIndicatorView.spinner()
    /// The progress row: the bar fills the track in the theme's accent.
    let track = CALayer()
    let bar = CALayer()
    private(set) var actionButtons: [SidebarUpdateButton] = []
    /// The action drawn as a switch (``SidebarNoticeCard/Action/isSwitch``), right of the buttons; nil until one shows.
    private(set) var actionSwitch: SidebarCardSwitch?
    /// The notice the card shows (or last showed, during its exit) has a switch action.
    private var hasSwitch = false
    let closeButton = SidebarIconButton(icon: .actionClose, pointSize: { 9 }, label: "")
    /// The card's own control (``SidebarNoticeCard/trailing``), a quiet text button at the top right, on the
    /// title's row: a running download's Cancel. Lawrence 2026-11-07: "cancel button is ugly not taking up
    /// full width here" (the round cancel sat beside the progress bar, which stopped short of it).
    let trailingButton = SidebarCardTextButton()
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
        surface = CardSurfaceView(cornerRadius: Metrics.surfaceCornerRadius, reduceTransparency: reduceTransparency)
        self.motionPolicy = motionPolicy
        super.init(frame: frame)
        wantsLayer = true
        surface.takesThemeTint = true
        addSubview(surface)
        addSubview(content)
        for label in [eyebrowLabel, shortcutLabel] {
            label.lineBreakMode = .byTruncatingTail
            label.maximumNumberOfLines = 1
        }
        shortcutLabel.alignment = .right
        icon.imageScaling = .scaleProportionallyDown
        content.wantsLayer = true
        // Nothing draws past the card's rounded edge: a card laid out narrower than its rows (a sidebar laid out
        // small) drew its switch past its leading edge, alone, with no card around it (Lawrence msg 19185).
        content.layer?.masksToBounds = true
        track.cornerRadius = Metrics.capsuleRadius(CGSize(width: 3, height: 3))
        bar.cornerRadius = Metrics.capsuleRadius(CGSize(width: 3, height: 3))
        // The bar lives in the track, which clips it: the unmeasured sweep never leaves the track.
        track.masksToBounds = true
        content.layer?.addSublayer(track)
        track.addSublayer(bar)
        closeButton.takesKeyFocus = true
        closeButton.onPress = { [weak self] in self?.closePressed() }
        dismissButton.onPress = { [weak self] in if let id = self?.notice?.id { self?.onDismiss?(id) } }
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
        laidOut = notice
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
                let label = Self.wrappingLabel()
                label.stringValue = Self.bullet + line
                content.addSubview(label)
                return label
            }
        }
        shortcutLabel.stringValue = notice.shortcut ?? ""
        shortcutLabel.isHidden = notice.shortcut == nil || notice.actions.isEmpty
        let spins = Self.spins(notice)
        icon.isHidden = notice.symbol == nil || spins
        spinner.spin(spins)
        closeButton.isHidden = notice.dismissLabel == nil || notice.dismissTitle != nil
        closeButton.label = notice.dismissLabel ?? ""
        dismissButton.isHidden = notice.dismissTitle == nil
        dismissButton.configure(title: notice.dismissTitle ?? "", help: notice.dismissLabel)
        if previous?.actions != notice.actions {
            rebuildButtons(notice.actions)
            // New buttons under the pointer (Checking… turning into the found update's Update): a
            // click meant for what was there must not press them, above all an Update that, with
            // `updates.oneClickInstall`, restarts cmux. Keys and VoiceOver still press them.
            actionButtons.forEach { $0.ignorePointer() }
        }
        trailingButton.isHidden = notice.trailing == nil
        if let trailing = notice.trailing {
            trailingButton.configure(title: trailing.label, help: nil)
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

    /// Where a card with a symbol (or its spinner) draws it. Leo 2026-11-05, on the hang-reports card: "why is the
    /// text under it? Also giving negative space away ... the buttons and the subtitle text is in a different
    /// indentation level". The card ships ``above``; the others are the gallery's directions
    /// (`AASidebarNoticeCardGalleryTests`). A card with neither starts every row at the card's padding.
    enum GlyphPlacement: CaseIterable, Sendable {
        /// On the x's row, above the title: the title, detail and buttons start at the card's padding, as the icon does.
        case above
        /// In a leading column beside the title: the title, detail and buttons start after it.
        case column
        /// Before the title on its row: the detail and buttons start at the card's padding.
        case inline
    }

    /// Where the card draws its symbol (``GlyphPlacement``).
    var glyphPlacement = GlyphPlacement.above { didSet { needsLayout = true } }

    /// Every row's frame for a notice in a card `width` wide, and the card's height: the one measure
    /// that sizes the card (``height(for:width:)``) and places its views (`layout()`), so the
    /// card is always as tall as its wrapped title, detail, lines and button rows.
    struct Frames {
        /// The symbol or spinner; nil for none.
        var glyph: CGRect?
        /// The glyph has a row of its own (``GlyphPlacement/above``), which the x shares.
        var glyphRow = false
        var eyebrow: CGRect?
        var title = CGRect.zero
        var detail: CGRect?
        var lines: [CGRect] = []
        var progress: CGRect?
        /// The buttons, in order; a button that does not fit after the one before starts a new row.
        var buttons: [CGRect] = []
        /// The last button row's top, and where its buttons end (the shortcut and the switch go after them).
        var lastRow: (y: CGFloat, end: CGFloat) = (0, 0)
        var height: CGFloat = 0
    }

    /// Unmeasured work shows a spinner where the symbol goes.
    private static func spins(_ notice: SidebarNoticeCard) -> Bool { notice.progress == .indeterminate && notice.leadingSpinner }

    /// A loading card's detail counts (bytes, seconds): tabular digits keep each count's width.
    private static func detailFont(_ notice: SidebarNoticeCard?) -> NSFont {
        notice?.progress != nil ? Typography.captionDigits : Typography.caption
    }

    /// A label that wraps at its width with no line limit and never truncates.
    private static func wrappingLabel() -> ChromeLabel {
        let label = ChromeLabel(wrappingLabelWithString: "")
        label.maximumNumberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        label.truncatesLastVisibleLine = false
        label.isSelectable = false
        return label
    }

    /// The height `text` takes in `font` wrapped in a label frame `width` wide, measured in `label` (made by
    /// ``wrappingLabel()``, as the card's own labels are).
    private static func textHeight(_ text: String, font: NSFont, width: CGFloat, in label: ChromeLabel) -> CGFloat {
        label.font = font
        label.stringValue = text
        return ceil(label.size(forWidth: width).height)
    }

    /// A button's width for its title: the label and its inset, never wider than the row.
    private static func buttonWidth(_ title: String, row: CGFloat) -> CGFloat {
        let text = ceil((title as NSString).size(withAttributes: [.font: SidebarUpdateButton.font]).width)
        return max(0, min(row, text + 2 * Metrics.space4))
    }

    /// The height of a card showing `notice` `width` wide, for a card not made yet (tests, the gallery). The slot
    /// asks its card (``height(for:width:)``), which keeps its last measure.
    static func height(for notice: SidebarNoticeCard, width: CGFloat, placement: GlyphPlacement = .above) -> CGFloat {
        let dismiss = SidebarCardTextButton(), trailing = SidebarCardTextButton()
        dismiss.configure(title: notice.dismissTitle ?? "", help: nil)
        trailing.configure(title: notice.trailing?.label ?? "", help: nil)
        return measureFrames(for: notice, width: width, dismissWidth: notice.dismissTitle == nil ? 0 : dismiss.fittingWidth,
                             trailingWidth: notice.trailing == nil ? 0 : trailing.fittingWidth,
                             placement: placement, measuring: wrappingLabel()).height
    }

    /// This card's height for `notice` (the one it shows) in a card `width` wide.
    func height(for notice: SidebarNoticeCard, width: CGFloat) -> CGFloat { frames(for: notice, width: width).height }

    /// The rows of `notice` (the one the card shows) in a card `width` wide. The sidebar sizes the slot and the card
    /// lays itself out on every pass: the text is measured again only when the notice, width or type size changes.
    private func frames(for notice: SidebarNoticeCard, width: CGFloat) -> Frames {
        let dismissWidth = notice.dismissTitle == nil ? 0 : dismissButton.fittingWidth
        let trailingWidth = notice.trailing == nil ? 0 : trailingButton.fittingWidth
        let key = FramesKey(notice: notice, width: width, dismissWidth: dismissWidth, trailingWidth: trailingWidth, placement: glyphPlacement,
                            scale: [Self.padding, Metrics.space1, Metrics.space2, Metrics.space4, Typography.caption.pointSize,
                                    Typography.bodyEmphasized.pointSize, SidebarUpdateButton.font.pointSize, SidebarUpdateButton.height],
                            faces: [Typography.caption.fontName, Typography.bodyEmphasized.fontName, SidebarUpdateButton.font.fontName])
        if let measured, measured.key == key { return measured.frames }
        let frames = Self.measureFrames(for: notice, width: width, dismissWidth: dismissWidth, trailingWidth: trailingWidth,
                                        placement: glyphPlacement, measuring: measuring)
        measured = (key, frames)
        return frames
    }

    private struct FramesKey: Hashable {
        var notice: SidebarNoticeCard
        var width: CGFloat
        var dismissWidth: CGFloat
        var trailingWidth: CGFloat
        var placement: GlyphPlacement
        /// Every spacing and type size the rows are measured in (the trailing control's side included), and the faces.
        var scale: [CGFloat]
        var faces: [String]
    }

    /// Measures wrapped text the way the card's labels lay it out.
    private let measuring = SidebarNoticeCardView.wrappingLabel()
    /// The last measure (``frames(for:width:)``).
    private var measured: (key: FramesKey, frames: Frames)?

    /// The rows of `notice` in a card `width` wide, top to bottom: padding, the glyph's row (``GlyphPlacement/above``),
    /// the heading, the title, the detail (two lines at least, so a loading card never changes height), the list lines,
    /// the progress bar, the button rows, padding. The title, detail and lines wrap in full; nothing truncates.
    private static func measureFrames(for notice: SidebarNoticeCard, width: CGFloat, dismissWidth: CGFloat, trailingWidth: CGFloat,
                                      placement: GlyphPlacement, measuring: ChromeLabel) -> Frames {
        let pad = padding, line = lineHeight, glyphSide = line.body
        var frames = Frames()
        let showsGlyph = notice.symbol != nil || spins(notice)
        frames.glyphRow = showsGlyph && placement == .above
        // The card's own control (a download's Cancel) is a text button on the first row, at the top right, as the
        // text dismiss is: only that row leaves it room. The detail and the bar span the whole inner width in every
        // stage (Lawrence 2026-11-07: "cancel button is ugly not taking up full width here").
        let trailingRoom = notice.trailing == nil ? 0 : trailingWidth + Metrics.space1
        let closeRoom = notice.dismissTitle != nil ? dismissWidth + Metrics.space1
            : (notice.dismissLabel == nil ? 0 : closeSide) + trailingRoom
        let titleX = pad + (showsGlyph && !frames.glyphRow ? glyphSide + Metrics.space2 : 0)
        let bodyX = placement == .column ? titleX : pad
        var y = pad
        if frames.glyphRow {
            frames.glyph = CGRect(x: pad, y: y, width: glyphSide, height: glyphSide)
            y += glyphSide + Metrics.space2
        }
        if notice.eyebrow != nil {
            frames.eyebrow = CGRect(x: pad, y: y, width: max(0, width - 2 * pad - (frames.glyphRow ? 0 : closeRoom)), height: line.caption)
            y += line.caption
        }
        if showsGlyph, !frames.glyphRow { frames.glyph = CGRect(x: pad, y: y, width: glyphSide, height: glyphSide) }
        // The title shares the x's row when nothing is above it, and the text button's (``SidebarNoticeCard/dismissTitle``) always.
        let titleHasX = !frames.glyphRow && (notice.eyebrow == nil || notice.dismissTitle != nil)
        let titleWidth = max(0, width - pad - titleX - (titleHasX ? closeRoom : 0))
        let titleHeight = max(line.body, textHeight(notice.title, font: Typography.bodyEmphasized, width: titleWidth, in: measuring))
        frames.title = CGRect(x: titleX, y: y, width: titleWidth, height: titleHeight)
        y += titleHeight
        let bodyWidth = max(0, width - pad - bodyX)
        if let detail = notice.detail {
            let height = max(2 * line.caption, textHeight(detail, font: detailFont(notice), width: bodyWidth, in: measuring))
            frames.detail = CGRect(x: bodyX, y: y + Metrics.space1, width: bodyWidth, height: height)
            y += Metrics.space1 + height
        }
        let lines = notice.lines.prefix(maxLines)
        if !lines.isEmpty { y += Metrics.space1 }
        for text in lines {
            let height = max(line.caption, textHeight(Self.bullet + text, font: Typography.caption, width: bodyWidth, in: measuring))
            frames.lines.append(CGRect(x: bodyX, y: y, width: bodyWidth, height: height))
            y += height
        }
        // Every loading stage keeps the bar's row (Lawrence 2026-10-20: "needs better loading
        // indicator"): Checking to Downloading to Installing never changes the card's height.
        if notice.progress != nil {
            y += Metrics.space2
            frames.progress = CGRect(x: bodyX, y: y, width: bodyWidth, height: barHeight)
            y += barHeight
        }
        if !notice.actions.isEmpty {
            y += Metrics.space2
            let rowEnd = width - pad, row = max(0, rowEnd - bodyX)
            var x = bodyX
            for action in notice.actions.filter({ !$0.isSwitch }).prefix(2) {
                let wide = Self.buttonWidth(action.title, row: row)
                // A button that does not fit after the one before starts the next row: none is squeezed or cut off.
                if x > bodyX, x + wide > rowEnd {
                    x = bodyX
                    y += SidebarUpdateButton.height + Metrics.space2
                }
                frames.buttons.append(CGRect(x: x, y: y, width: wide, height: SidebarUpdateButton.height))
                x += wide + Metrics.space2
            }
            frames.lastRow = (y, x)
            y += SidebarUpdateButton.height
        }
        frames.height = ceil(y + pad)
        return frames
    }

    /// A list line's mark.
    private static let bullet = "• "

    override func layout() {
        super.layout()
        let b = bounds, pad = Self.padding, line = Self.lineHeight, close = Self.closeSide
        surface.frame = b
        surface.cornerRadius = Metrics.surfaceCornerRadius
        content.layer?.cornerRadius = Metrics.surfaceCornerRadius
        content.layer?.cornerCurve = .continuous
        content.frame = b
        eyebrowLabel.font = Typography.caption
        titleLabel.font = Typography.bodyEmphasized
        // The exit shows the last notice as it was.
        let shown = notice ?? laidOut
        detailLabel.font = Self.detailFont(shown)
        shortcutLabel.font = Typography.caption
        let dismissWidth = dismissButton.fittingWidth, dismissHeight = SidebarCardTextButton.height
        let rows = shown.map { frames(for: $0, width: b.width) } ?? Frames()
        eyebrowLabel.frame = rows.eyebrow ?? .zero
        icon.frame = rows.glyph ?? NSRect(x: pad, y: rows.title.minY, width: line.body, height: line.body)
        spinner.frame = icon.frame
        titleLabel.frame = rows.title
        detailLabel.frame = rows.detail ?? .zero
        for (label, frame) in zip(lineLabels, rows.lines) {
            label.font = Typography.caption
            label.frame = frame
        }
        // The x and the text button sit on the first row: the glyph's own, else the heading's or the title's. The x
        // centers on that row's capitals (live-qa 2026-10-21: centered in the padding corner it sat a point above the heading).
        let first = eyebrowLabel.isHidden ? titleLabel : eyebrowLabel
        let rowMid = rows.glyphRow ? icon.frame.midY
            : first.frame.minY + first.firstBaselineOffsetFromTop - (first.font?.capHeight ?? 0) / 2
        let dismissMid = rows.glyphRow ? icon.frame.midY : titleLabel.frame.minY + line.body / 2
        dismissButton.frame = NSRect(x: b.width - pad / 2 - dismissWidth, y: dismissMid - dismissHeight / 2, width: dismissWidth, height: dismissHeight)
        let scale = window?.backingScaleFactor ?? 2
        closeButton.frame = NSRect(x: b.width - pad / 2 - close, y: ((rowMid - close / 2) * scale).rounded() / scale,
                                   width: close, height: close)
        // The card's Cancel: a text button on the first row at the top right, left of the x when the card has one.
        let trailingWidth = trailingButton.fittingWidth
        let trailingEnd = closeButton.isHidden ? b.width - pad / 2 : closeButton.frame.minX - Metrics.space1
        trailingButton.frame = NSRect(x: trailingEnd - trailingWidth, y: dismissMid - dismissHeight / 2, width: trailingWidth, height: dismissHeight)
        layoutProgress(rows.progress)
        for (button, frame) in zip(actionButtons, rows.buttons) { button.frame = frame }
        let rowY = rows.lastRow.y, x = rows.lastRow.end
        if let actionSwitch {
            // The switch shows whole on the last button row, after the buttons, or not at all: squeezed, it drew its
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
            // The bar is the theme's accent (the primary text with none chosen), never a fixed gray.
            bar.backgroundColor = Palette.accentFill.cgColor
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
