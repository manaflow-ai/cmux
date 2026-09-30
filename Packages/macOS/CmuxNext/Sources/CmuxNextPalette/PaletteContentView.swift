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
            if !actionsMenuView.isHidden { fade(actionsMenuView, in: false) }
            return
        }
        actionsMenuView.update(state, alternateID: model.selectedItem?.alternate?.id)
        menuHeight = PaletteActionsMenuView.height(for: state)
        let wasHidden = actionsMenuView.isHidden
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

    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// Springs open from 96.5% scale anchored at the top edge, with a fade.
    func animateIn() {
        guard let layer else { return }
        layoutSubtreeIfNeeded()
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = reduceMotion ? 0.12 : 0.18
        layer.add(fade, forKey: "palette.fade")
        guard !reduceMotion else { return }
        let spring = CASpringAnimation(keyPath: "sublayerTransform")
        spring.fromValue = NSValue(caTransform3D: scaleAboutTopCenter(0.965))
        spring.toValue = NSValue(caTransform3D: CATransform3DIdentity)
        spring.mass = 1
        spring.stiffness = 420
        spring.damping = 30
        spring.duration = spring.settlingDuration
        layer.add(spring, forKey: "palette.scale")
    }

    /// Fades out (with a slight shrink) and calls `completion` when done.
    func animateOut(completion: @escaping @MainActor () -> Void) {
        guard let layer else {
            completion()
            return
        }
        CATransaction.begin()
        CATransaction.setCompletionBlock { MainActor.assumeIsolated { completion() } }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        fade.duration = reduceMotion ? 0.1 : 0.14
        fade.fillMode = .forwards
        fade.isRemovedOnCompletion = false
        layer.add(fade, forKey: "palette.fade")
        if !reduceMotion {
            let shrink = CABasicAnimation(keyPath: "sublayerTransform")
            shrink.fromValue = NSValue(caTransform3D: CATransform3DIdentity)
            shrink.toValue = NSValue(caTransform3D: scaleAboutTopCenter(0.98))
            shrink.duration = fade.duration
            shrink.timingFunction = CAMediaTimingFunction(name: .easeIn)
            shrink.fillMode = .forwards
            shrink.isRemovedOnCompletion = false
            layer.add(shrink, forKey: "palette.scale")
        }
        CATransaction.commit()
    }

    /// Clears finished close animations so the next open starts clean.
    func resetAnimations() {
        layer?.removeAnimation(forKey: "palette.fade")
        layer?.removeAnimation(forKey: "palette.scale")
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

    private func fade(_ view: NSView, in appearing: Bool) {
        view.isHidden = false
        if appearing { view.alphaValue = 0 }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = reduceMotion ? 0.08 : 0.14
            view.animator().alphaValue = appearing ? 1 : 0
        } completionHandler: {
            MainActor.assumeIsolated { if !appearing { view.isHidden = true } }
        }
    }
}
