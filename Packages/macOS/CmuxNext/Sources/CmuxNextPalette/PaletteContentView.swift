import AppKit
import CmuxNextDesign
import Observation
import QuartzCore

/// The palette surface: a Liquid Glass panel with the search bar, result
/// list, and footer, plus the Actions menu floating above the footer. Pure
/// AppKit. Renders from `PaletteModel` through Observation tracking and
/// applies only what changed, so an idle palette does no work.
final class PaletteContentView: NSView {
    let model: PaletteModel
    /// Called when Design tokens change the palette's size while it is open.
    var onPreferredSizeChange: ((CGSize) -> Void)?

    let searchBar = PaletteSearchBar()
    private let stage = FlippedView()
    /// The panel's material: glass, or opaque under Reduce Transparency.
    let glass = Glass.makeOverlayPanel(cornerRadius: PaletteLayout.cornerRadius)
    private let body = FlippedView()
    private let topRule = NSView()
    private let bottomRule = NSView()
    private let list = PaletteListView()
    /// Hosts the results and fades them out at the top or bottom while more
    /// are hidden there.
    private lazy var listHost = ScrollEdgeFadeView(scrollView: list)
    private let emptyTitle = PaletteText.label(Typography.bodyEmphasized, tone: .secondary)
    private let emptyHint = PaletteText.label(Typography.caption, tone: .tertiary)
    /// The page's line under the field (`PaletteModel.fieldHint`).
    private let fieldHint = PaletteText.label(Typography.caption, tone: .tertiary)
    private let footer = PaletteFooterView()
    private let actionsMenuView = PaletteActionsMenuView()
    private let recorderView = PaletteShortcutRecorderView()
    private var recorderHeight: CGFloat = 0
    /// A click on a shortcut recorder choice.
    var onRecorderOption: ((PaletteShortcutOption) -> Void)? {
        get { recorderView.onChoose }
        set { recorderView.onChoose = newValue }
    }

    private var appliedResults = -1
    private var appliedScroll = -1
    private var appliedPage = -1
    private var appliedSize = CGSize.zero
    private var menuHeight: CGFloat = 0
    private var actionsMenuFadingOut = false

    init(model: PaletteModel) {
        self.model = model
        super.init(frame: NSRect(origin: .zero, size: PaletteLayout.windowSize))
        wantsLayer = true
        layer?.masksToBounds = false
        glass.translatesAutoresizingMaskIntoConstraints = true
        glass.contentView.addSubview(body)
        emptyTitle.stringValue = PaletteStrings.noResults
        emptyHint.stringValue = PaletteStrings.noResultsHint
        emptyTitle.alignment = .center
        emptyHint.alignment = .center
        [topRule, bottomRule].forEach { $0.wantsLayer = true }
        fieldHint.isHidden = true
        [searchBar, fieldHint, topRule, listHost, emptyTitle, emptyHint, bottomRule, footer].forEach(body.addSubview)
        stage.addSubview(glass)
        stage.addSubview(actionsMenuView)
        stage.addSubview(recorderView)
        actionsMenuView.isHidden = true
        recorderView.isHidden = true
        stage.wantsLayer = true
        addSubview(stage)
        wire()
        observe()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func focusField() {
        window?.makeFirstResponder(searchBar.field)
        if let editor = searchBar.field.currentEditor() as? NSTextView {
            applyEditorColors(editor)
            // A search query is not prose: no spelling, grammar or
            // replacement checks (their text checking ran on every open).
            editor.isContinuousSpellCheckingEnabled = false
            editor.isGrammarCheckingEnabled = false
            editor.isAutomaticSpellingCorrectionEnabled = false
            editor.isAutomaticTextReplacementEnabled = false
            editor.isAutomaticQuoteSubstitutionEnabled = false
            editor.isAutomaticDashSubstitutionEnabled = false
            editor.isAutomaticTextCompletionEnabled = false
            editor.isAutomaticDataDetectionEnabled = false
            editor.isAutomaticLinkDetectionEnabled = false
        }
        let length = searchBar.field.stringValue.utf16.count
        searchBar.field.currentEditor()?.selectedRange = model.selectsQuery
            ? NSRange(location: 0, length: min(model.selectedQueryLength ?? length, length)) : NSRange(location: length, length: 0)
    }

    private func wire() {
        let model = model
        searchBar.onQueryChange = { model.query = $0 }
        searchBar.onPopTo = { model.pop(to: $0) }
        searchBar.onKeywordHint = { model.handle(.openActions) }
        list.onHover = { model.hover($0) }
        list.onActivate = { model.activate(rowID: $0) }
        footer.onPrimary = { model.handle(.submit) }
        footer.onActions = { model.handle(.toggleActions) }
        footer.onCrumb = { model.openCrumb(at: $0) }
        footer.onClose = { model.handle(.closeItem) }
        actionsMenuView.onRun = { model.runActionsMenuCommand(at: $0) }
    }

    // MARK: Rendering

    private func observe() {
        withObservationTracking {
            render()
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.observe() }
        }
    }

    private func render() {
        // Read every tracked input up front so tracking sees all of them.
        let resultsVersion = model.resultsVersion
        let sections = model.sections
        let selection = model.selectedRowID
        let hover = model.hoveredRowID
        let scroll = model.scrollRequest
        let pageToken = model.pageToken
        let menuState = model.actionsMenu
        let recorderState = model.shortcutRecorder
        let size = PaletteLayout.windowSize

        if resultsVersion != appliedResults {
            appliedResults = resultsVersion
            list.setSections(sections)
        }
        list.setSelection(selection)
        list.setHover(hover)
        if scroll != appliedScroll {
            appliedScroll = scroll
            list.scrollToSelection()
        }
        let showEmpty = sections.isEmpty && !model.isLoading
        listHost.isHidden = showEmpty
        emptyTitle.isHidden = !showEmpty
        emptyHint.isHidden = !showEmpty

        searchBar.update(
            query: model.query,
            placeholder: model.placeholder,
            chips: model.scopeChips,
            rootTitle: model.navigation.graph.root.title,
            style: model.chipStyle,
            keywordHint: model.keywordHint?.title,
            isLoading: model.isLoading
        )
        footer.update(
            pageTitle: model.prefixHints ?? model.pageTitle,
            pageSymbol: model.pageSymbol,
            primaryTitle: model.primaryTitle,
            actionsEnabled: model.selectedItem?.isEnabled == true,
            closeTitle: model.selectedItem.flatMap { $0.isEnabled ? $0.closeCommand?.title : nil },
            crumbs: model.pageCrumbs
        )
        if fieldHint.stringValue != model.fieldHint ?? "" || fieldHint.isHidden != (model.fieldHint == nil) {
            fieldHint.stringValue = model.fieldHint ?? ""
            fieldHint.isHidden = model.fieldHint == nil
            needsLayout = true
        }
        if pageToken != appliedPage {
            appliedPage = pageToken
            focusField()
        }
        updateMenu(menuState)
        updateRecorder(recorderState)
        if size != appliedSize {
            appliedSize = size
            list.relayoutRows()
            onPreferredSizeChange?(size)
            needsLayout = true
        }
    }

    private func updateRecorder(_ state: PaletteShortcutRecorderState?) {
        guard let state else {
            recorderView.isHidden = true
            return
        }
        recorderView.update(state)
        recorderHeight = PaletteShortcutRecorderView.height(for: state)
        recorderView.isHidden = false
        needsLayout = true
    }

    private func updateMenu(_ state: PaletteActionsMenuState?) {
        guard let state else {
            if !actionsMenuView.isHidden, !actionsMenuFadingOut { fade(actionsMenuView, in: false) }
            return
        }
        actionsMenuView.update(state, alternateID: model.selectedItem?.alternate?.id)
        menuHeight = PaletteActionsMenuView.height(for: state)
        // Fading out counts as hidden, so a reopen retargets the fade.
        let wasHidden = actionsMenuView.isHidden || actionsMenuFadingOut
        needsLayout = true
        layoutSubtreeIfNeeded()
        if wasHidden { fade(actionsMenuView, in: true) }
    }

    // MARK: Layout

    override func layout() {
        super.layout()
        let margin = PaletteLayout.shadowMargin
        stage.frame = bounds
        glass.frame = NSRect(x: margin, y: margin, width: PaletteLayout.width, height: PaletteLayout.height)
        glass.cornerRadius = PaletteLayout.cornerRadius
        body.frame = CGRect(origin: .zero, size: glass.bounds.size)
        let width = body.bounds.width
        var y: CGFloat = 0
        searchBar.frame = NSRect(x: 0, y: y, width: width, height: PaletteLayout.searchHeight)
        y += PaletteLayout.searchHeight
        // The hint takes its line from the top of the list.
        let fieldHintHeight = fieldHint.isHidden ? 0 : fieldHint.intrinsicContentSize.height + Metrics.space2
        fieldHint.frame = NSRect(x: PaletteLayout.horizontalPadding, y: y,
                                 width: width - 2 * PaletteLayout.horizontalPadding, height: fieldHintHeight)
        y += fieldHintHeight
        topRule.frame = NSRect(x: 0, y: y, width: width, height: Metrics.dividerThickness)
        y += Metrics.dividerThickness
        let listFrame = NSRect(x: 0, y: y, width: width, height: PaletteLayout.listHeight - fieldHintHeight)
        listHost.frame = listFrame
        list.contentInsets = NSEdgeInsets(top: PaletteLayout.listInset, left: 0, bottom: PaletteLayout.listInset, right: 0)
        let titleHeight = emptyTitle.intrinsicContentSize.height
        let hintHeight = emptyHint.intrinsicContentSize.height
        let emptyTop = listFrame.midY - (titleHeight + Metrics.space2 + hintHeight) / 2
        emptyTitle.frame = NSRect(x: 0, y: emptyTop, width: width, height: titleHeight)
        emptyHint.frame = NSRect(x: 0, y: emptyTop + titleHeight + Metrics.space2, width: width, height: hintHeight)
        y += PaletteLayout.listHeight - fieldHintHeight
        bottomRule.frame = NSRect(x: 0, y: y, width: width, height: Metrics.dividerThickness)
        y += Metrics.dividerThickness
        footer.frame = NSRect(x: 0, y: y, width: width, height: PaletteLayout.footerHeight)
        // The recorder floats over the top of the list, under the field.
        let recorderWidth = min(PaletteLayout.width - 2 * Metrics.space6, PaletteLayout.actionsMenuWidth * 1.5)
        recorderView.frame = NSRect(x: glass.frame.midX - recorderWidth / 2, y: glass.frame.minY + PaletteLayout.searchHeight + Metrics.space4,
                                    width: recorderWidth, height: recorderHeight)
        let menuWidth = PaletteLayout.actionsMenuWidth
        actionsMenuView.frame = NSRect(
            x: glass.frame.maxX - menuWidth - Metrics.space4,
            y: glass.frame.minY + y - menuHeight - Metrics.space2,
            width: menuWidth,
            height: menuHeight
        )
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
        needsLayout = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyColors()
    }

    /// Theme colors, again on every theme change (the panel adopts the
    /// scope of the window it opens over).
    private func applyColors() {
        performWithTheme {
            glass.applyTheme()
            topRule.layer?.backgroundColor = Palette.separator.cgColor
            bottomRule.layer?.backgroundColor = Palette.separator.cgColor
            let shadow = NSShadow()
            shadow.shadowColor = Palette.shadow.withAlphaComponent(0.22)
            shadow.shadowBlurRadius = PaletteLayout.shadowRadius
            shadow.shadowOffset = NSSize(width: 0, height: -PaletteLayout.shadowOffset)
            stage.shadow = shadow
        }
        if let editor = searchBar.field.currentEditor() as? NSTextView { applyEditorColors(editor) }
    }

    /// Gray selection and caret; the system accent never shows.
    private func applyEditorColors(_ editor: NSTextView) {
        performWithTheme {
            editor.selectedTextAttributes = [.backgroundColor: Palette.selectionFill]
            editor.insertionPointColor = Palette.textPrimary
        }
    }

    // MARK: Animation

    /// Opens with a fade and an `appear` spring from
    /// `Motion.panelOpenScale` about the panel's center. Reopening while the
    /// close still runs continues from what is on screen instead of
    /// restarting from zero.
    func animateIn() {
        guard let layer else { return }
        layoutSubtreeIfNeeded()
        let closing = layer.animation(forKey: "opacity") != nil
        Motion.set(layer, "opacity", to: Float(1), fade: .fadeIn, from: closing ? nil : Float(0))
        Motion.set(layer, "sublayerTransform", to: NSValue(caTransform3D: CATransform3DIdentity), spring: .appear,
                   from: closing ? nil : NSValue(caTransform3D: panelScale(Motion.panelOpenScale)))
    }

    /// Closes faster than it opened: a `fadeOut` with a slight shrink to
    /// `Motion.panelCloseScale` about the center; calls `completion` when done.
    func animateOut(completion: @escaping @MainActor () -> Void) {
        guard let layer else {
            completion()
            return
        }
        CATransaction.begin()
        CATransaction.setCompletionBlock { MainActor.assumeIsolated { completion() } }
        Motion.set(layer, "opacity", to: Float(0), fade: .fadeOut)
        Motion.set(layer, "sublayerTransform", to: NSValue(caTransform3D: panelScale(Motion.panelCloseScale)), fade: .fadeOut)
        CATransaction.commit()
    }

    /// Clears finished close animations so the next open starts clean.
    func resetAnimations() {
        layer?.removeAnimation(forKey: "opacity")
        layer?.removeAnimation(forKey: "sublayerTransform")
    }

    /// Center of the glass panel in this view's coordinates.
    var panelCenter: CGPoint {
        let margin = PaletteLayout.shadowMargin
        return CGPoint(x: margin + PaletteLayout.width / 2, y: bounds.height - margin - PaletteLayout.height / 2)
    }

    /// The panel scaled about its own center (`Motion.scale` accounts for
    /// the backing layer's (0, 0) anchor point).
    func panelScale(_ scale: CGFloat) -> CATransform3D {
        guard let layer else { return CATransform3DIdentity }
        return Motion.scale(scale, about: panelCenter, in: layer)
    }

    /// Fades the actions menu. The fade starts from the view's current
    /// presentation opacity, so a reopen mid-fade does not jump.
    private func fade(_ view: NSView, in appearing: Bool) {
        if view.isHidden {
            view.alphaValue = 0
            view.isHidden = false
        }
        actionsMenuFadingOut = !appearing
        Motion.animate(appearing ? .fadeIn : .fadeOut, { view.animator().alphaValue = appearing ? 1 : 0 }, completion: { [weak self] in
            guard let self, self.actionsMenuFadingOut, !appearing else { return }
            self.actionsMenuFadingOut = false
            view.isHidden = true
        })
    }
}
