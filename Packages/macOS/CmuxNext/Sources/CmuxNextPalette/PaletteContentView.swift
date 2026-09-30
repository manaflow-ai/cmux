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
    private let glass = Glass.makePanel(cornerRadius: PaletteLayout.cornerRadius)
    private let body = FlippedView()
    private let topRule = NSView()
    private let bottomRule = NSView()
    private let list = PaletteListView()
    private let emptyTitle = PaletteText.label(Typography.bodyEmphasized, color: Palette.textSecondary)
    private let emptyHint = PaletteText.label(Typography.caption, color: Palette.textTertiary)
    private let footer = PaletteFooterView()
    private let actionsMenuView = PaletteActionsMenuView()

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
        glass.contentView = body
        emptyTitle.stringValue = PaletteStrings.noResults
        emptyHint.stringValue = PaletteStrings.noResultsHint
        emptyTitle.alignment = .center
        emptyHint.alignment = .center
        [topRule, bottomRule].forEach { $0.wantsLayer = true }
        [searchBar, topRule, list, emptyTitle, emptyHint, bottomRule, footer].forEach(body.addSubview)
        stage.addSubview(glass)
        stage.addSubview(actionsMenuView)
        actionsMenuView.isHidden = true
        stage.wantsLayer = true
        stage.shadow = {
            let shadow = NSShadow()
            shadow.shadowColor = Palette.shadow.withAlphaComponent(0.22)
            shadow.shadowBlurRadius = PaletteLayout.shadowRadius
            shadow.shadowOffset = NSSize(width: 0, height: -PaletteLayout.shadowOffset)
            return shadow
        }()
        addSubview(stage)
        wire()
        observe()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func focusField() {
        window?.makeFirstResponder(searchBar.field)
        if let editor = searchBar.field.currentEditor() as? NSTextView {
            // Gray selection and caret; the system accent never shows.
            editor.selectedTextAttributes = [.backgroundColor: Palette.selectionFill]
            editor.insertionPointColor = Palette.textPrimary
        }
        searchBar.field.currentEditor()?.selectedRange = NSRange(location: searchBar.field.stringValue.utf16.count, length: 0)
    }

    private func wire() {
        let model = model
        searchBar.onQueryChange = { model.query = $0 }
        searchBar.onBack = { model.pop() }
        list.onHover = { model.hover($0) }
        list.onActivate = { model.activate(rowID: $0) }
        footer.onPrimary = { model.handle(.submit) }
        footer.onActions = { model.handle(.toggleActions) }
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
        list.isHidden = showEmpty
        emptyTitle.isHidden = !showEmpty
        emptyHint.isHidden = !showEmpty

        searchBar.update(
            query: model.query,
            placeholder: model.placeholder,
            breadcrumb: model.breadcrumbs.last,
            isLoading: model.isLoading
        )
        footer.update(
            pageTitle: model.pageTitle,
            pageSymbol: model.pageSymbol,
            primaryTitle: model.primaryTitle,
            actionsEnabled: model.selectedItem?.isEnabled == true
        )
        if pageToken != appliedPage {
            appliedPage = pageToken
            focusField()
        }
        updateMenu(menuState)
        if size != appliedSize {
            appliedSize = size
            list.relayoutRows()
            onPreferredSizeChange?(size)
            needsLayout = true
        }
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
        body.frame = glass.bounds
        let width = body.bounds.width
        var y: CGFloat = 0
        searchBar.frame = NSRect(x: 0, y: y, width: width, height: PaletteLayout.searchHeight)
        y += PaletteLayout.searchHeight
        topRule.frame = NSRect(x: 0, y: y, width: width, height: Metrics.dividerThickness)
        y += Metrics.dividerThickness
        let listFrame = NSRect(x: 0, y: y, width: width, height: PaletteLayout.listHeight)
        list.frame = listFrame
        list.contentInsets = NSEdgeInsets(top: PaletteLayout.listInset, left: 0, bottom: PaletteLayout.listInset, right: 0)
        let titleHeight = emptyTitle.intrinsicContentSize.height
        let hintHeight = emptyHint.intrinsicContentSize.height
        let emptyTop = listFrame.midY - (titleHeight + Metrics.space2 + hintHeight) / 2
        emptyTitle.frame = NSRect(x: 0, y: emptyTop, width: width, height: titleHeight)
        emptyHint.frame = NSRect(x: 0, y: emptyTop + titleHeight + Metrics.space2, width: width, height: hintHeight)
        y += PaletteLayout.listHeight
        bottomRule.frame = NSRect(x: 0, y: y, width: width, height: Metrics.dividerThickness)
        y += Metrics.dividerThickness
        footer.frame = NSRect(x: 0, y: y, width: width, height: PaletteLayout.footerHeight)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            topRule.layer?.backgroundColor = Palette.separator.cgColor
            bottomRule.layer?.backgroundColor = Palette.separator.cgColor
        }
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
        needsLayout = true
    }

    // MARK: Animation

    /// Opens with a fade and a spring from 97% scale anchored at the top
    /// edge (Spotlight-like). Reopening while the close still runs continues
    /// from what is on screen instead of restarting from zero.
    func animateIn() {
        guard let layer else { return }
        layoutSubtreeIfNeeded()
        let closing = layer.animation(forKey: "opacity") != nil
        Motion.set(layer, "opacity", to: Float(1), fade: .fadeIn, from: closing ? nil : Float(0))
        Motion.set(layer, "sublayerTransform", to: NSValue(caTransform3D: CATransform3DIdentity), spring: .panel,
                   from: closing ? nil : NSValue(caTransform3D: scaleAboutTopCenter(0.97)))
    }

    /// Fades out (with a slight shrink) faster than it opened and calls
    /// `completion` when done.
    func animateOut(completion: @escaping @MainActor () -> Void) {
        guard let layer else {
            completion()
            return
        }
        CATransaction.begin()
        CATransaction.setCompletionBlock { MainActor.assumeIsolated { completion() } }
        Motion.set(layer, "opacity", to: Float(0), fade: .fadeOut)
        Motion.set(layer, "sublayerTransform", to: NSValue(caTransform3D: scaleAboutTopCenter(0.98)), fade: .fadeOut)
        CATransaction.commit()
    }

    /// Clears finished close animations so the next open starts clean.
    func resetAnimations() {
        layer?.removeAnimation(forKey: "opacity")
        layer?.removeAnimation(forKey: "sublayerTransform")
    }

    private func scaleAboutTopCenter(_ scale: CGFloat) -> CATransform3D {
        // sublayerTransform pivots on the layer's center; shift the pivot to
        // the glass panel's top edge (maxY in the unflipped layer).
        let pivot = CGPoint(x: bounds.midX, y: bounds.height - PaletteLayout.shadowMargin)
        let dx = pivot.x - bounds.midX
        let dy = pivot.y - bounds.midY
        var transform = CATransform3DMakeTranslation(dx, dy, 0)
        transform = CATransform3DScale(transform, scale, scale, 1)
        return CATransform3DTranslate(transform, -dx, -dy, 0)
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
