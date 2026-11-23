import AppKit
import CmuxNextCompat
import CmuxNextDesign

/// The Density Overlay Playground's window content: a toolbar (reference, mode, opacity, zoom, tolerance, offset
/// nudges, Live, Controls) over a canvas that lays a reference capture on cmux's own browser chrome, and a status line
/// with the pixel diff. Pixels draw without smoothing, so the zoom is a loupe.
///
/// AppKit (plans/cmux-next/no-swiftui-DESIGN.md): the view reads ``DensityOverlayModel`` and the Settings theme in
/// ``render()``, again on every change of what it read (an `ObservationStream`); a tuned value or a density change
/// asks the model to capture again (``DensityOverlayModel/chromeDidChange()``).
final class DensityOverlayView: NSView {
    private let model: DensityOverlayModel
    private let openControls: () -> Void

    private let reference = ThemedPopUpButton(frame: .zero, pullsDown: true)
    private let modePicker = NSSegmentedControl()
    private let live = NSButton(checkboxWithTitle: DensityOverlayStrings.live, target: nil, action: nil)
    private var buttons: [DensityOverlayButton] = []
    private let opacity = NSSlider(value: 0.5, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let zoom = NSSlider(value: 2, minValue: 1, maxValue: 8, target: nil, action: nil)
    private let threshold = NSSlider(value: 24, minValue: 0, maxValue: 96, target: nil, action: nil)
    private var captions: [NSTextField] = []
    private let offsetLabel = NSTextField(labelWithString: "")
    private let toolbar = NSStackView()
    private let firstRow = NSStackView()
    private let secondRow = NSStackView()
    private let nudges = NSStackView()
    private let topSeparator = NSView()
    private let bottomSeparator = NSView()
    private let scroll = OverlayScrollView()
    private let canvas = DensityOverlayCanvas()
    private let status = NSTextField(labelWithString: "")
    private var toolbarInsets: [NSLayoutConstraint] = []
    private var statusInsets: [NSLayoutConstraint] = []
    private var separatorHeights: [NSLayoutConstraint] = []
    /// The reference menu as last built: the built-in references and the title.
    private var builtMenu: (references: [URL], title: String)?
    private var appeared = false
    // task-owner: the view's `following` and `chrome`, started when it joins a window and cancelled when it leaves.
    private var following: Task<Void, Never>?
    private var chrome: Task<Void, Never>?

    /// - Parameters:
    ///   - model: The playground's state; the toolbar writes it.
    ///   - openControls: Opens the Controls panel (the Controls… button).
    init(model: DensityOverlayModel, openControls: @escaping () -> Void) {
        self.model = model
        self.openControls = openControls
        super.init(frame: NSRect(x: 0, y: 0, width: 900, height: 520))
        build()
        render()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The status line's text (tests).
    var statusText: String { status.stringValue }

    // MARK: Build

    private func build() {
        let tokens = SettingsTheme.shared.tokens

        reference.controlSize = .small
        reference.font = Typography.body
        reference.setAccessibilityIdentifier("cmux.densityOverlay.reference")
        reference.setContentHuggingPriority(.required, for: .horizontal)
        // Rows have no action of their own: a pick runs the button's action, which reads the picked row.
        reference.target = self
        reference.action = #selector(referencePicked)

        modePicker.segmentCount = DensityOverlayModel.Mode.allCases.count
        for (index, mode) in DensityOverlayModel.Mode.allCases.enumerated() {
            modePicker.setLabel(DensityOverlayStrings.mode(mode), forSegment: index)
        }
        modePicker.trackingMode = .selectOne
        modePicker.segmentStyle = .automatic
        modePicker.controlSize = .small
        modePicker.font = Typography.body
        modePicker.target = self
        modePicker.action = #selector(modeChanged)

        live.controlSize = .small
        live.target = self
        live.action = #selector(liveChanged)

        let capture = DensityOverlayButton(title: DensityOverlayStrings.capture, tokens: tokens, target: self,
                                           action: #selector(captureNow))
        let controls = DensityOverlayButton(title: DensityOverlayStrings.controls, tokens: tokens, target: self,
                                            action: #selector(showControls))
        buttons = [capture, controls]

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        spacer.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        configure(firstRow, [reference, modePicker, spacer, live, capture, controls])

        configure(slider: opacity, width: 110, action: #selector(opacityChanged))
        configure(slider: zoom, width: 110, action: #selector(zoomChanged))
        configure(slider: threshold, width: 90, action: #selector(thresholdChanged))

        var nudgeViews: [NSView] = []
        for (arrow, dx, dy) in [("←", -1, 0), ("→", 1, 0), ("↑", 0, -1), ("↓", 0, 1)] as [(String, Int, Int)] {
            let button = DensityOverlayButton(title: arrow, tokens: tokens, target: self, action: #selector(nudge(_:)))
            button.tag = Self.nudgeTag(dx: dx, dy: dy)
            button.setAccessibilityLabel(DensityOverlayStrings.offset(dx, dy))
            buttons.append(button)
            nudgeViews.append(button)
        }
        offsetLabel.font = Typography.captionDigits
        nudgeViews.append(offsetLabel)
        configure(nudges, nudgeViews)

        configure(secondRow, [labeled(DensityOverlayStrings.opacity, opacity), labeled(DensityOverlayStrings.zoom, zoom),
                              labeled(DensityOverlayStrings.threshold, threshold), nudges])
        secondRow.setHuggingPriority(.required, for: .horizontal)

        toolbar.orientation = .vertical
        toolbar.alignment = .leading
        toolbar.addArrangedSubview(firstRow)
        toolbar.addArrangedSubview(secondRow)
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        firstRow.widthAnchor.constraint(equalTo: toolbar.widthAnchor).isActive = true

        for separator in [topSeparator, bottomSeparator] {
            separator.wantsLayer = true
            separator.translatesAutoresizingMaskIntoConstraints = false
        }

        canvas.onClick = { [weak self] in
            guard let model = self?.model, model.mode == .flip else { return }
            model.flip()
        }
        scroll.contentView = FlippedClipView()
        scroll.documentView = canvas
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        SystemScrollers.follow(scroll)

        status.isSelectable = true
        status.focusRingType = .none
        status.font = Typography.caption
        status.lineBreakMode = .byTruncatingTail
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        status.setAccessibilityIdentifier("cmux.densityOverlay.status")
        status.translatesAutoresizingMaskIntoConstraints = false

        for view in [toolbar, topSeparator, scroll, bottomSeparator, status] as [NSView] { addSubview(view) }
        toolbarInsets = [
            toolbar.topAnchor.constraint(equalTo: topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: leadingAnchor),
            trailingAnchor.constraint(equalTo: toolbar.trailingAnchor),
            topSeparator.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
        ]
        statusInsets = [
            status.topAnchor.constraint(equalTo: bottomSeparator.bottomAnchor),
            status.leadingAnchor.constraint(equalTo: leadingAnchor),
            trailingAnchor.constraint(equalTo: status.trailingAnchor),
            bottomAnchor.constraint(equalTo: status.bottomAnchor),
        ]
        separatorHeights = [topSeparator.heightAnchor.constraint(equalToConstant: 1),
                            bottomSeparator.heightAnchor.constraint(equalToConstant: 1)]
        NSLayoutConstraint.activate(toolbarInsets + statusInsets + separatorHeights + [
            topSeparator.leadingAnchor.constraint(equalTo: leadingAnchor),
            topSeparator.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topSeparator.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            bottomSeparator.topAnchor.constraint(equalTo: scroll.bottomAnchor),
            bottomSeparator.leadingAnchor.constraint(equalTo: leadingAnchor),
            bottomSeparator.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    private func configure(_ row: NSStackView, _ views: [NSView]) {
        row.orientation = .horizontal
        row.alignment = .centerY
        for view in views { row.addArrangedSubview(view) }
    }

    private func configure(slider: NSSlider, width: CGFloat, action: Selector) {
        slider.controlSize = .small
        slider.isContinuous = true
        slider.target = self
        slider.action = action
        slider.widthAnchor.constraint(equalToConstant: width).isActive = true
    }

    private func labeled(_ title: String, _ control: NSView) -> NSStackView {
        let caption = NSTextField(labelWithString: title)
        caption.font = Typography.caption
        captions.append(caption)
        let row = NSStackView()
        configure(row, [caption, control])
        return row
    }

    // MARK: Observation

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        following?.cancel()
        chrome?.cancel()
        following = nil
        chrome = nil
        guard window != nil else { return }
        if !appeared {
            appeared = true
            model.appear()
        }
        following = Task { [weak self] in
            for await _ in ObservationStream({ [weak self] in _ = self?.touchRenderState() }) {
                guard let self, !Task.isCancelled else { return }
                render()
            }
        }
        // A tuned value or the density changed: capture again (the SwiftUI view's two `onChange`s). The first value
        // is the state now, not a change.
        chrome = Task { [weak self] in
            var first = true
            for await _ in ObservationStream({ ChromeKey(revision: TunableStore.shared.revision, tokens: Metrics.tokens) }) {
                guard let self, !Task.isCancelled else { return }
                if first { first = false } else { model.chromeDidChange() }
            }
        }
    }

    /// The window shows again after a close (the SwiftUI view's `onAppear`).
    func reappear() { model.appear() }

    /// What a tuned value or a density change is.
    private nonisolated struct ChromeKey: Equatable, Sendable {
        var revision: Int
        var tokens: DensityTokens
    }

    /// Reads everything ``render()`` shows, for the observation (it changes nothing).
    private func touchRenderState() {
        _ = model.mode
        _ = model.reference
        _ = model.referenceName
        _ = model.builtInReferences
        _ = model.live
        _ = model.diff
        _ = model.noBrowserPane
        _ = model.opacity
        _ = model.zoom
        _ = model.offset
        _ = model.threshold
        _ = model.flipShowsReference
        _ = model.isLive
        _ = SettingsTheme.shared.tokens
        _ = Borders.drawsLines
        _ = Metrics.tokens
    }

    // MARK: Render

    /// Shows the model and the theme: the controls' values, the canvas and the status line.
    func render() {
        let tokens = SettingsTheme.shared.tokens
        let space1 = Metrics.space1, space2 = Metrics.space2, space3 = Metrics.space3, space5 = Metrics.space5

        toolbarInsets[0].constant = Metrics.titlebarHeight
        toolbarInsets[1].constant = space5
        toolbarInsets[2].constant = space5
        toolbarInsets[3].constant = space3
        statusInsets[0].constant = space3
        statusInsets[1].constant = space5
        statusInsets[2].constant = space5
        statusInsets[3].constant = space3
        for height in separatorHeights { height.constant = Metrics.dividerThickness }
        toolbar.spacing = space3
        firstRow.spacing = space3
        secondRow.spacing = space5
        nudges.spacing = space1
        for case let row as NSStackView in secondRow.arrangedSubviews where row !== nudges { row.spacing = space2 }

        let separator = Borders.drawsLines ? tokens.separator.nsColor.cgColor : NSColor.clear.cgColor
        topSeparator.layer?.backgroundColor = separator
        bottomSeparator.layer?.backgroundColor = separator
        let tint = tokens.focusRing.nsColor
        for slider in [opacity, zoom, threshold] { slider.trackFillColor = tint }
        modePicker.selectedSegmentBezelColor = tint
        live.bezelColor = tint
        live.attributedTitle = NSAttributedString(string: DensityOverlayStrings.live, attributes: [
            .font: Typography.body, .foregroundColor: tokens.textPrimary.nsColor,
        ])
        for button in buttons { button.tokens = tokens }
        for caption in captions { caption.textColor = tokens.textSecondary.nsColor }
        offsetLabel.textColor = tokens.textSecondary.nsColor
        status.textColor = tokens.textSecondary.nsColor

        renderReferenceMenu()
        if let index = DensityOverlayModel.Mode.allCases.firstIndex(of: model.mode), modePicker.selectedSegment != index {
            modePicker.selectedSegment = index
        }
        live.state = model.isLive ? .on : .off
        if opacity.doubleValue != model.opacity { opacity.doubleValue = model.opacity }
        if zoom.doubleValue != model.zoom { zoom.doubleValue = model.zoom }
        if threshold.doubleValue != model.threshold { threshold.doubleValue = model.threshold }
        offsetLabel.stringValue = DensityOverlayStrings.offset(Int(model.offset.x), Int(model.offset.y))

        canvas.state = DensityOverlayCanvasState(
            mode: model.mode, reference: model.reference, live: model.live, flipShowsReference: model.flipShowsReference,
            scale: model.zoom / 2, // the captures are 2x: one image pixel is half a point at zoom 1
            offset: model.offset, opacity: model.opacity, spacing: space3, padding: space5)

        status.stringValue = statusLine
    }

    /// The pull-down's title item and the references, rebuilt only when they change.
    private func renderReferenceMenu() {
        let title = model.referenceName ?? DensityOverlayStrings.reference
        let references = model.builtInReferences
        if let builtMenu, builtMenu.references == references, builtMenu.title == title { return }
        builtMenu = (references, title)
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: title, action: nil, keyEquivalent: ""))
        for url in references {
            let item = NSMenuItem(title: url.deletingPathExtension().lastPathComponent, action: nil, keyEquivalent: "")
            item.representedObject = url
            menu.addItem(item)
        }
        menu.addItem(.separator())
        // No represented URL: referencePicked asks for an image.
        menu.addItem(NSMenuItem(title: DensityOverlayStrings.chooseReference, action: nil, keyEquivalent: ""))
        reference.menu = menu
    }

    private var statusLine: String {
        if model.noBrowserPane { return DensityOverlayStrings.noBrowserPane }
        guard model.reference != nil else { return DensityOverlayStrings.noReference }
        guard let diff = model.diff else { return "" }
        guard let bounds = diff.bounds else { return DensityOverlayStrings.matches }
        let percent = diff.fraction.formatted(.percent.precision(.fractionLength(1)))
        return DensityOverlayStrings.differing(diff.differing, of: diff.total, percent: percent) + " · "
            + DensityOverlayStrings.differenceBounds(Int(bounds.minX), Int(bounds.maxX) - 1, Int(bounds.minY), Int(bounds.maxY) - 1)
    }

    // MARK: Actions

    /// A pull-down pick: a built-in reference loads its URL; "Choose Image…" (no URL) asks for one.
    @objc private func referencePicked() {
        guard let item = reference.selectedItem, reference.indexOfSelectedItem > 0 else { return }
        if let url = item.representedObject as? URL { model.loadReference(url) } else { model.chooseReference() }
    }

    @objc private func modeChanged() {
        let modes = DensityOverlayModel.Mode.allCases
        guard modes.indices.contains(modePicker.selectedSegment) else { return }
        model.mode = modes[modePicker.selectedSegment]
    }

    @objc private func liveChanged() { model.isLive = live.state == .on }

    @objc private func captureNow() { model.capture() }

    @objc private func showControls() { openControls() }

    @objc private func opacityChanged() { model.opacity = opacity.doubleValue }

    /// Whole steps, as the SwiftUI slider's `step: 1`.
    @objc private func zoomChanged() {
        let value = zoom.doubleValue.rounded()
        if model.zoom != value { model.zoom = value }
    }

    /// Steps of 4, as the SwiftUI slider's `step: 4`.
    @objc private func thresholdChanged() {
        let value = (threshold.doubleValue / 4).rounded() * 4
        if model.threshold != value { model.threshold = value }
    }

    @objc private func nudge(_ sender: NSButton) {
        let (dx, dy) = Self.nudgeOffset(tag: sender.tag)
        model.nudge(dx: CGFloat(dx), dy: CGFloat(dy))
    }

    private static func nudgeTag(dx: Int, dy: Int) -> Int { (dx + 1) * 3 + (dy + 1) }
    private static func nudgeOffset(tag: Int) -> (Int, Int) { (tag / 3 - 1, tag % 3 - 1) }
}

/// A clip view that lays its document from the top left, as the SwiftUI scroll view did.
private final class FlippedClipView: NSClipView {
    override var isFlipped: Bool { true }
}
