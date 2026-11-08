import AppKit
import CmuxSpinner
import ImageIO
import UniformTypeIdentifiers

/// cmux: the large picture viewer over a Chief chat pane (the user, 2026-11-05, on a Before|After table: "i want
/// to be able to expand and annotate"). A click on a picture in a table card (or a picture bubble) opens it: the
/// pane dims and blurs under it, it fits the pane and zooms (pinch, Command-plus and -minus, Command-0 to fit, a
/// double-click for its own size) and pans (scroll, or drag with Move). The arrow keys and the side buttons step
/// through the table's pictures; C (or Compare) shows the row's Before and After side by side, where a click or
/// Space flips one picture in place (B and A pick one) and the bar's style control also offers the slider
/// (``HomePictureCompare``). The tools mark it up (arrow, box, pen, text; Command-Z undoes); Send in Chat hands the
/// marked picture to the message box, Copy and Save keep it. One Esc closes it, whatever has focus in it (the user,
/// 2026-11-07: "i have to press esc twice to close it"). Like ``HomeVideoViewer`` it stays inside its pane.
@MainActor
final class HomePictureViewer: NSView {
    /// What a key does in the viewer (``handle(_:)``; `keyDown` maps the real keys to it).
    enum Key: Equatable, Sendable {
        case left, right, escape, compare, undo, zoomIn, zoomOut, fit
        /// In the comparison: flip the shown picture to its pair (Space), or show Before (B) or After (A) alone.
        case flip, before, after
        /// The row above or below in the comparison ("Light" ↔ "Dark").
        case up, down
    }

    typealias Load = @MainActor (HomePictureGallery.Item) async -> CGImage?

    private(set) var gallery: HomePictureGallery
    private(set) var isComparing = false
    /// The viewer closed.
    var onClose: () -> Void = {}
    /// Send in Chat: the marked-up picture's PNG.
    var onReply: (URL) -> Void = { _ in }

    private let load: Load
    private let replies: HomePictureReply
    private var images: [Int: CGImage] = [:]
    private var failed: Set<Int> = []
    private var markups: [Int: HomePictureMarkup] = [:]
    private var loading: Task<Void, Never>?

    private let backdrop = NSVisualEffectView(frame: .zero)
    private let dim = NSView(frame: .zero)
    private let scroll = NSScrollView(frame: .zero)
    private let canvas = HomePictureCanvas(frame: .zero)
    private let compare = HomePictureCompare(frame: .zero)
    private let titleLabel = NSTextField(labelWithString: "")
    private let counterLabel = NSTextField(labelWithString: "")
    private let status = NSTextField(labelWithString: "")
    private let spinner = CmuxSpinnerView(side: 32)
    private let closeButton = NSButton(frame: .zero)
    private let previousButton = NSButton(frame: .zero)
    private let nextButton = NSButton(frame: .zero)
    private let bar = NSVisualEffectView(frame: .zero)
    private let tools = NSSegmentedControl(frame: .zero)
    /// In the comparison, in the tools' place: Side by Side, Flip, Slider (``HomePictureCompare/Style``).
    private let styles = NSSegmentedControl(frame: .zero)
    /// The comparison's rows ("Light | Dark"), when the gallery's rows have labels.
    private let rowSwitch = NSSegmentedControl(frame: .zero)
    private var rowSwitchRows: [Int] = []
    /// The opening's matched geometry: the thumbnail clicked and its frame in this view (``present(from:thumbnail:)``).
    private var origin: (rect: CGRect, image: CGImage, index: Int)?
    /// Whether Reduce Motion is on (tests pass a fixed answer): the viewer then opens and closes at once.
    var reduceMotion: () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    /// The open and close's length, seconds.
    static let openDuration: CFTimeInterval = 0.3
    static let closeDuration: CFTimeInterval = 0.22
    /// Ease out, quick start and a long settle (the open's motion).
    static let easeOut = CAMediaTimingFunction(controlPoints: 0.22, 1, 0.36, 1)
    private var barButtons: [NSButton] = []
    private var compareButton: NSButton?
    private var undoButton: NSButton?
    private var textField: NSTextField?
    private var textAt: CGPoint = .zero
    private var closed = false

    /// - Parameter load: decodes an item's full picture (the app reads the file or downloads the web picture).
    init(frame: NSRect, gallery: HomePictureGallery, load: @escaping Load, reply: HomePictureReply = HomePictureReply()) {
        self.gallery = gallery
        self.load = load
        self.replies = reply
        super.init(frame: frame)
        wantsLayer = true
        autoresizingMask = [.width, .height]
        backdrop.material = .hudWindow
        backdrop.blendingMode = .withinWindow
        backdrop.state = .active
        dim.wantsLayer = true
        dim.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.6).cgColor

        scroll.contentView = HomePictureClipView(frame: .zero)
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = true
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.allowsMagnification = true
        scroll.minMagnification = 0.05
        scroll.maxMagnification = 8
        scroll.documentView = canvas
        canvas.onMark = { [weak self] mark in self?.addMark(mark) }
        canvas.onTextAt = { [weak self] pixels, point in self?.beginText(at: pixels, viewPoint: point) }
        canvas.onToggleZoom = { [weak self] in self?.toggleActualSize() }
        compare.isHidden = true

        for label in [titleLabel, counterLabel, status] {
            label.textColor = .white
            label.lineBreakMode = .byTruncatingMiddle
        }
        titleLabel.font = HomeFonts.system(ofSize: 13, weight: .semibold)
        counterLabel.font = HomeFonts.system(ofSize: 12)
        counterLabel.textColor = NSColor.white.withAlphaComponent(0.7)
        status.alignment = .center
        status.textColor = NSColor.white.withAlphaComponent(0.75)
        spinner.appearance = NSAppearance(named: .darkAqua)

        Self.style(closeButton, symbol: "xmark.circle.fill", label: CmuxStrings.closePictureViewer, size: 20)
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        Self.style(previousButton, symbol: "chevron.left.circle.fill", label: CmuxStrings.picturePrevious, size: 28)
        previousButton.target = self
        previousButton.action = #selector(previousClicked)
        Self.style(nextButton, symbol: "chevron.right.circle.fill", label: CmuxStrings.pictureNext, size: 28)
        nextButton.target = self
        nextButton.action = #selector(nextClicked)

        bar.material = .hudWindow
        bar.blendingMode = .withinWindow
        bar.state = .active
        bar.wantsLayer = true
        bar.layer?.cornerRadius = 12
        bar.layer?.masksToBounds = true
        bar.appearance = NSAppearance(named: .vibrantDark)
        let toolList: [(HomePictureCanvas.Tool, String, String)] = [
            (.move, "hand.raised", CmuxStrings.pictureToolMove),
            (.arrow, "arrow.up.right", CmuxStrings.pictureToolArrow),
            (.box, "rectangle", CmuxStrings.pictureToolBox),
            (.pen, "scribble", CmuxStrings.pictureToolPen),
            (.text, "textformat", CmuxStrings.pictureToolText),
        ]
        tools.segmentCount = toolList.count
        tools.trackingMode = .selectOne
        tools.segmentStyle = .separated
        for (i, entry) in toolList.enumerated() {
            tools.setImage(NSImage(systemSymbolName: entry.1, accessibilityDescription: entry.2), forSegment: i)
            tools.setToolTip(entry.2, forSegment: i)
            tools.setWidth(30, forSegment: i)
        }
        tools.selectedSegment = 0
        tools.target = self
        tools.action = #selector(toolChanged)
        bar.addSubview(tools)
        let styleList: [(HomePictureCompare.Style, String, String)] = [
            (.sideBySide, "rectangle.split.2x1", CmuxStrings.pictureStyleSideBySide),
            (.flip, "arrow.left.arrow.right.square", CmuxStrings.pictureStyleFlip),
            (.slider, "slider.horizontal.below.rectangle", CmuxStrings.pictureStyleSlider),
        ]
        styles.segmentCount = styleList.count
        styles.trackingMode = .selectOne
        styles.segmentStyle = .separated
        for (i, entry) in styleList.enumerated() {
            styles.setImage(NSImage(systemSymbolName: entry.1, accessibilityDescription: entry.2), forSegment: i)
            styles.setToolTip(entry.2, forSegment: i)
            styles.setWidth(30, forSegment: i)
        }
        styles.selectedSegment = HomePictureCompare.Style.sideBySide.rawValue
        styles.target = self
        styles.action = #selector(styleChanged)
        styles.setAccessibilityLabel(CmuxStrings.pictureStyle)
        styles.isHidden = true
        bar.addSubview(styles)
        compare.onStyle = { [weak self] style in self?.styles.selectedSegment = style.rawValue }
        let undo = barButton("arrow.uturn.backward", CmuxStrings.pictureUndo, #selector(undoClicked))
        undoButton = undo
        let cmp = barButton("rectangle.split.2x1", CmuxStrings.pictureCompare, #selector(compareClicked))
        compareButton = cmp
        barButtons = [undo, cmp,
                      barButton("doc.on.doc", CmuxStrings.pictureCopy, #selector(copyClicked)),
                      barButton("square.and.arrow.down", CmuxStrings.pictureSave, #selector(saveClicked)),
                      barButton("arrowshape.turn.up.left.fill", CmuxStrings.pictureReply, #selector(replyClicked))]
        for b in barButtons { bar.addSubview(b) }

        rowSwitchRows = gallery.labeledRows
        rowSwitch.segmentCount = rowSwitchRows.count
        rowSwitch.trackingMode = .selectOne
        rowSwitch.segmentStyle = .capsule
        rowSwitch.appearance = NSAppearance(named: .vibrantDark)
        for (i, row) in rowSwitchRows.enumerated() {
            rowSwitch.setLabel(gallery.rowLabels[row] ?? "", forSegment: i)
            rowSwitch.setWidth(0, forSegment: i)
        }
        rowSwitch.target = self
        rowSwitch.action = #selector(rowSwitched)
        rowSwitch.setAccessibilityLabel(CmuxStrings.pictureRowSwitch)
        rowSwitch.isHidden = true

        for v in [backdrop, dim, scroll, compare, status, spinner, titleLabel, counterLabel, previousButton, nextButton, bar, rowSwitch, closeButton] as [NSView] {
            addSubview(v)
        }
        setAccessibilityRole(.group)
        setAccessibilityLabel(CmuxStrings.pictureViewer)
        show()
        if gallery.opensComparing { setComparing(true) }
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    private static func style(_ b: NSButton, symbol: String, label: String, size: CGFloat) {
        b.bezelStyle = .circular
        b.isBordered = false
        b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        b.symbolConfiguration = .init(pointSize: size, weight: .regular)
        b.contentTintColor = NSColor.white.withAlphaComponent(0.85)
        b.toolTip = label
        b.setAccessibilityLabel(label)
    }

    private func barButton(_ symbol: String, _ label: String, _ action: Selector) -> NSButton {
        let b = NSButton(frame: .zero)
        Self.style(b, symbol: symbol, label: label, size: 14)
        b.target = self
        b.action = action
        return b
    }

    // MARK: Showing

    /// Waits for the shown picture's load (tests, and the reply that needs its pixels).
    func loaded() async { await loading?.value }

    private var currentImage: CGImage? { images[gallery.index] }

    private func show() {
        let item = gallery.current
        titleLabel.stringValue = item?.title ?? ""
        counterLabel.stringValue = gallery.items.count > 1 ? CmuxStrings.pictureCounter(gallery.index + 1, gallery.items.count) : ""
        previousButton.isHidden = gallery.items.count < 2
        nextButton.isHidden = gallery.items.count < 2
        previousButton.isEnabled = gallery.index > 0
        nextButton.isEnabled = gallery.index < gallery.items.count - 1
        compareButton?.isEnabled = gallery.partner(of: gallery.index) != nil
        canvas.markup = markups[gallery.index] ?? HomePictureMarkup()
        undoButton?.isEnabled = !canvas.markup.marks.isEmpty
        if let image = currentImage {
            place(image)
        } else {
            canvas.image = nil
            canvas.frame = .zero
        }
        refreshStatus()
        if isComparing { showCompare() }
        if let at = rowSwitchRows.firstIndex(of: item?.row ?? -1) { rowSwitch.selectedSegment = at }
        loadMissing()
        needsLayout = true
    }

    private func refreshStatus() {
        let waiting = currentImage == nil && !failed.contains(gallery.index)
        status.stringValue = failed.contains(gallery.index) ? CmuxStrings.pictureLoadFailed : ""
        if waiting { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        spinner.setAccessibilityLabel(CmuxStrings.pictureLoading)
    }

    /// Loads the shown picture and the one it compares with (and the neighbours, so stepping is instant).
    private func loadMissing() {
        let i = gallery.index
        var wanted = [i]
        if let p = gallery.partner(of: i) { wanted.append(p) }
        wanted += [i + 1, i - 1].filter { gallery.items.indices.contains($0) }
        let missing = wanted.filter { images[$0] == nil && !failed.contains($0) }
        guard !missing.isEmpty else { return }
        let previous = loading
        // task-owner: the viewer; each picture loads once, the shown one first.
        loading = Task { [weak self] in
            await previous?.value
            for index in missing {
                // A closed viewer (close() cancels this task) stops loading and drops its reference at once.
                guard !Task.isCancelled, let self, !self.closed else { return }
                guard let item = self.gallery.items[checked: index], self.images[index] == nil else { continue }
                let image = await self.load(item)
                guard !Task.isCancelled, !self.closed else { return }
                if let image { self.images[index] = image } else { self.failed.insert(index) }
                if index == self.gallery.index || index == self.gallery.partner(of: self.gallery.index) { self.show() }
            }
        }
    }

    private func place(_ image: CGImage) {
        let points = CGSize(width: max(1, CGFloat(image.width) / 2), height: max(1, CGFloat(image.height) / 2))
        if canvas.image !== image {
            canvas.image = image
            canvas.frame = CGRect(origin: .zero, size: points)
            fit()
        }
    }

    private func fit() {
        layoutSubtreeIfNeeded()
        let size = canvas.frame.size
        let room = scroll.bounds.size
        guard size.width > 0, size.height > 0, room.width > 0, room.height > 0 else { return }
        scroll.magnification = min(1, room.width / size.width, room.height / size.height)
    }

    private func toggleActualSize() {
        let size = canvas.frame.size, room = scroll.bounds.size
        let fitted = min(1, room.width / max(1, size.width), room.height / max(1, size.height))
        if abs(scroll.magnification - fitted) < 0.01 { scroll.magnification = 1 } else { scroll.magnification = fitted }
    }

    private func showCompare() {
        let i = gallery.index
        guard let p = gallery.partner(of: i) else { return }
        let (a, b) = p > i ? (i, p) : (p, i)
        compare.first = images[a]
        compare.second = images[b]
        compare.firstTitle = gallery.items[checked: a]?.title ?? ""
        compare.secondTitle = gallery.items[checked: b]?.title ?? ""
    }

    private func setComparing(_ on: Bool) {
        isComparing = on && gallery.partner(of: gallery.index) != nil
        compare.isHidden = !isComparing
        scroll.isHidden = isComparing
        tools.isHidden = isComparing
        styles.isHidden = !isComparing
        rowSwitch.isHidden = !isComparing || rowSwitchRows.count < 2
        // The switch takes room in the top bar: the title's space changes with it.
        needsLayout = true
        if isComparing { showCompare() }
        compareButton?.state = isComparing ? .on : .off
        compareButton?.contentTintColor = isComparing ? .controlAccentColor : NSColor.white.withAlphaComponent(0.85)
    }

    override func layout() {
        super.layout()
        backdrop.frame = bounds
        dim.frame = bounds
        let top = HomePictureViewerTopBar.height, bottom: CGFloat = 64, side: CGFloat = gallery.items.count > 1 ? 56 : 20
        let area = CGRect(x: side, y: top, width: max(0, bounds.width - 2 * side), height: max(0, bounds.height - top - bottom))
        scroll.frame = area
        compare.frame = area
        let topBar = HomePictureViewerTopBar(
            width: bounds.width,
            titleWidth: naturalWidth(titleLabel),
            center: rowSwitch.isHidden ? .zero : rowSwitch.fittingSize,
            counterWidth: naturalWidth(counterLabel),
            avoiding: topBarObstacles)
        titleLabel.frame = topBar.title
        rowSwitch.frame = topBar.center
        counterLabel.frame = topBar.counter
        counterLabel.alignment = .right
        closeButton.frame = topBar.close
        previousButton.frame = CGRect(x: 12, y: bounds.midY - 18, width: 36, height: 36)
        nextButton.frame = CGRect(x: bounds.maxX - 48, y: bounds.midY - 18, width: 36, height: 36)
        spinner.frame = CGRect(x: bounds.midX - 16, y: bounds.midY - 16, width: 32, height: 32)
        status.frame = CGRect(x: 20, y: bounds.midY - 10, width: max(0, bounds.width - 40), height: 20)
        let shownTools = isComparing ? styles : tools
        let toolsWidth = shownTools.fittingSize.width
        let buttonWidth: CGFloat = 32
        let barWidth = 12 + toolsWidth + 12 + CGFloat(barButtons.count) * buttonWidth + 8
        bar.frame = CGRect(x: (bounds.midX - barWidth / 2).rounded(), y: bounds.maxY - 50, width: barWidth, height: 38)
        for control in [tools, styles] {
            control.frame = CGRect(x: 12, y: (38 - control.fittingSize.height) / 2, width: control.fittingSize.width, height: control.fittingSize.height)
        }
        var x = shownTools.frame.maxX + 12
        for b in barButtons {
            b.frame = CGRect(x: x, y: 5, width: buttonWidth, height: 28)
            x += buttonWidth
        }
        if let textField {
            textField.frame.size.width = max(160, min(320, bounds.width - textField.frame.minX - 20))
        }
    }

    /// The width `label` needs for its whole text, with the label cell's 2-point side insets (0 when empty). Not the
    /// intrinsic width: a truncating label's follows its current frame, so a short frame kept it short ("Ligh…After").
    private func naturalWidth(_ label: NSTextField) -> CGFloat {
        guard !label.stringValue.isEmpty else { return 0 }
        return max(label.cell?.cellSize.width ?? 0, label.attributedStringValue.size().width + 4).rounded(.up)
    }

    /// Controls the pane floats over the viewer's top bar, in the viewer's coordinates: visible views drawn above
    /// it (the Home chat column's round compose button is the chat's sibling, above it) and the window's traffic
    /// lights, where they reach into the bar. A view half the viewer's width or wider is an overlay, not a control.
    private var topBarObstacles: [CGRect] {
        let band = CGRect(x: 0, y: 0, width: bounds.width, height: HomePictureViewerTopBar.height)
        var found: [CGRect] = []
        var child: NSView = self
        while let parent = child.superview, child !== window?.contentView {
            for view in parent.subviews.drop(while: { $0 !== child }).dropFirst() where !view.isHidden && view.alphaValue > 0 {
                let rect = convert(view.bounds, from: view)
                if rect.intersects(band), rect.width < bounds.width / 2 { found.append(rect) }
            }
            child = parent
        }
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            guard let button = window?.standardWindowButton(kind), !button.isHiddenOrHasHiddenAncestor else { continue }
            let rect = convert(button.bounds, from: button)
            if rect.intersects(band) { found.append(rect) }
        }
        return found
    }

    // MARK: Keys

    /// Does what `key` does in the viewer; false when it does nothing here.
    @discardableResult
    func handle(_ key: Key) -> Bool {
        switch key {
        case .escape:
            // One Esc closes, from the words being typed or the comparison too.
            endText(commit: false)
            close()
        case .left, .right:
            let next = gallery.moved(by: key == .left ? -1 : 1)
            guard next.index != gallery.index else { return true }
            endText(commit: true)
            gallery = next
            show()
        case .compare: setComparing(!isComparing)
        case .flip, .before, .after:
            guard isComparing else { return false }
            let second = switch key {
            case .before: false
            case .after: true
            default: compare.style == .flip ? !compare.showsSecond : false
            }
            compare.flip(toSecond: second)
        case .up, .down:
            guard let row = gallery.current?.row, let at = rowSwitchRows.firstIndex(of: row),
                  let target = rowSwitchRows[checked: at + (key == .up ? -1 : 1)] else { return false }
            showRow(target)
        case .undo:
            var markup = markups[gallery.index] ?? HomePictureMarkup()
            markup.undo()
            markups[gallery.index] = markup
            canvas.markup = markup
            undoButton?.isEnabled = !markup.marks.isEmpty
        case .zoomIn: scroll.magnification = min(scroll.maxMagnification, scroll.magnification * 1.25)
        case .zoomOut: scroll.magnification = max(scroll.minMagnification, scroll.magnification / 1.25)
        case .fit: fit()
        }
        return true
    }

    override func keyDown(with event: NSEvent) {
        let command = event.modifierFlags.contains(.command)
        let key: Key? = switch (event.keyCode, event.charactersIgnoringModifiers?.lowercased() ?? "") {
        case (53, _): .escape
        case (123, _): .left
        case (124, _): .right
        case (126, _) where isComparing: .up
        case (125, _) where isComparing: .down
        case (_, "z") where command: .undo
        case (_, "="), (_, "+"): command ? .zoomIn : nil
        case (_, "-") where command: .zoomOut
        case (_, "0") where command: .fit
        case (_, "c") where command: nil
        case (_, "c"): .compare
        case (49, _) where isComparing: .flip
        case (_, "b") where isComparing && !command: .before
        case (_, "a") where isComparing && !command: .after
        default: nil
        }
        if let key { handle(key); return }
        if command, event.charactersIgnoringModifiers?.lowercased() == "c" { copyClicked(); return }
        super.keyDown(with: event)
    }

    override func cancelOperation(_ sender: Any?) { handle(.escape) }

    /// A click outside the picture and the controls closes the viewer.
    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let picture = isComparing ? compare.pictureFrame.offsetBy(dx: compare.frame.minX, dy: compare.frame.minY)
            : convert(canvas.bounds, from: canvas)
        if !picture.contains(p), !bar.frame.contains(p) { close() }
    }

    // MARK: Marks

    /// Adds `mark` to the shown picture's marks.
    func addMark(_ mark: HomePictureMarkup.Mark) {
        var markup = markups[gallery.index] ?? HomePictureMarkup()
        markup.add(mark)
        markups[gallery.index] = markup
        canvas.markup = markup
        undoButton?.isEnabled = true
    }

    private func beginText(at pixels: CGPoint, viewPoint: CGPoint) {
        endText(commit: true)
        textAt = pixels
        let field = NSTextField(frame: CGRect(origin: convert(viewPoint, from: canvas), size: CGSize(width: 220, height: 24)))
        field.placeholderString = CmuxStrings.pictureTextPlaceholder
        field.font = HomeFonts.system(ofSize: 14, weight: .semibold)
        field.textColor = NSColor(cgColor: HomePictureMarkup.ink)
        field.target = self
        field.action = #selector(textCommitted)
        addSubview(field)
        textField = field
        window?.makeFirstResponder(field)
    }

    @objc private func textCommitted() { endText(commit: true) }

    private func endText(commit: Bool) {
        guard let field = textField else { return }
        textField = nil
        let words = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        field.removeFromSuperview()
        if commit, !words.isEmpty { addMark(.text(at: textAt, words)) }
        window?.makeFirstResponder(self)
    }

    /// The shown picture with its marks, at its own pixels; nil until it loaded.
    func markedImage() -> CGImage? {
        guard let image = currentImage else { return nil }
        let markup = markups[gallery.index] ?? HomePictureMarkup()
        return markup.marks.isEmpty ? image : markup.render(onto: image)
    }

    /// Send in Chat: the marked picture as a PNG to ``onReply``, and the viewer closes.
    func reply() {
        endText(commit: true)
        guard let image = markedImage(), let url = replies.write(image, title: gallery.current?.title ?? "") else { NSSound.beep(); return }
        onReply(url)
        close()
    }

    // MARK: Actions

    @objc private func toolChanged() {
        canvas.tool = HomePictureCanvas.Tool(rawValue: tools.selectedSegment) ?? .move
        endText(commit: true)
    }
    @objc private func undoClicked() { handle(.undo) }
    @objc private func rowSwitched() {
        guard let row = rowSwitchRows[checked: rowSwitch.selectedSegment] else { return }
        showRow(row)
    }

    /// Shows row `row`'s picture in the same column (the comparison's Light | Dark switch).
    private func showRow(_ row: Int) {
        let next = gallery.moved(toRow: row)
        guard next.index != gallery.index else { return }
        endText(commit: true)
        gallery = next
        // The pair changes in place: a quick crossfade, none with Reduce Motion.
        if !reduceMotion(), let layer = compare.layer ?? scroll.layer {
            let fade = CATransition()
            fade.type = .fade
            fade.duration = 0.16
            layer.add(fade, forKey: "row")
        }
        show()
    }
    @objc private func compareClicked() { handle(.compare) }
    @objc private func previousClicked() { handle(.left) }
    @objc private func nextClicked() { handle(.right) }
    @objc private func closeClicked() { close() }

    @objc private func styleChanged() {
        guard let style = HomePictureCompare.Style(rawValue: styles.selectedSegment) else { return }
        showCompareStyle(style)
    }

    /// Shows the comparison as `style`, as its control in the bar does.
    func showCompareStyle(_ style: HomePictureCompare.Style) {
        styles.selectedSegment = style.rawValue
        compare.style = style
    }
    @objc private func replyClicked() { reply() }

    @objc private func copyClicked() {
        guard let image = markedImage() else { return }
        let board = NSPasteboard.general
        board.clearContents()
        board.writeObjects([NSImage(cgImage: image, size: CGSize(width: image.width / 2, height: image.height / 2))])
    }

    @objc private func saveClicked() {
        guard let image = markedImage(), let window else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = (gallery.current?.url.deletingPathExtension().lastPathComponent ?? "picture") + "-marked.png"
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url,
                  let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
            CGImageDestinationAddImage(dest, image, nil)
            _ = CGImageDestinationFinalize(dest)
        }
    }

    /// The viewer closed (it may still be fading out over the pane).
    var isClosed: Bool { closed }

    /// A closing viewer takes no clicks: the chat under it has them again.
    override func hitTest(_ point: NSPoint) -> NSView? { closed ? nil : super.hitTest(point) }

    /// Opens from the thumbnail clicked: `image` at `rect` (in this view) grows into the viewer's picture while
    /// the pane dims, and closing shrinks it back there (matched geometry). With Reduce Motion it is at once.
    func present(from rect: CGRect, thumbnail image: CGImage) {
        origin = (rect, image, gallery.index)
        guard !reduceMotion(), rect.width > 0, rect.height > 0 else { return }
        layoutSubtreeIfNeeded()
        let chrome = subviews.filter { $0 !== backdrop && $0 !== dim }
        for v in chrome { v.alphaValue = 0 }
        backdrop.alphaValue = 0
        dim.alphaValue = 0
        let ghost = Self.ghost(image, frame: rect)
        layer?.addSublayer(ghost)
        let target = Self.fitted(CGSize(width: image.width, height: image.height), in: isComparing ? compare.frame : scroll.frame)
        CATransaction.begin()
        CATransaction.setAnimationDuration(Self.openDuration)
        CATransaction.setAnimationTimingFunction(Self.easeOut)
        // The block runs on the main thread, in this main-actor method's isolation: the ghost goes once the real
        // picture shows.
        CATransaction.setCompletionBlock { [weak self] in
            ghost.removeFromSuperlayer()
            guard let self, !self.closed else { return }
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.12
                for v in chrome { v.animator().alphaValue = 1 }
            }
        }
        Self.move(ghost, from: rect, to: target)
        CATransaction.commit()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Self.openDuration * 0.8
            backdrop.animator().alphaValue = 1
            dim.animator().alphaValue = 1
        }
    }

    /// `size` scaled to fit `area`, centred.
    static func fitted(_ size: CGSize, in area: CGRect) -> CGRect {
        guard size.width > 0, size.height > 0, area.width > 0, area.height > 0 else { return area }
        let scale = min(area.width / size.width, area.height / size.height)
        let w = (size.width * scale).rounded(), h = (size.height * scale).rounded()
        return CGRect(x: (area.midX - w / 2).rounded(), y: (area.midY - h / 2).rounded(), width: w, height: h)
    }

    private static func ghost(_ image: CGImage, frame: CGRect) -> CALayer {
        let ghost = CALayer()
        ghost.contents = image
        ghost.contentsGravity = .resizeAspect
        ghost.frame = frame
        ghost.cornerRadius = 8
        ghost.masksToBounds = true
        ghost.zPosition = 10
        ghost.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull(), "frame": NSNull()]
        return ghost
    }

    /// Moves `layer` from `from` to `to` (its model takes `to` now) with an explicit animation, in the current
    /// transaction's duration and timing (so the transaction's completion waits for it).
    private static func move(_ layer: CALayer, from: CGRect, to: CGRect) {
        layer.frame = to
        let bounds = CABasicAnimation(keyPath: "bounds")
        bounds.fromValue = NSValue(rect: CGRect(origin: .zero, size: from.size))
        bounds.toValue = NSValue(rect: CGRect(origin: .zero, size: to.size))
        let position = CABasicAnimation(keyPath: "position")
        position.fromValue = NSValue(point: CGPoint(x: from.midX, y: from.midY))
        position.toValue = NSValue(point: CGPoint(x: to.midX, y: to.midY))
        let group = CAAnimationGroup()
        group.animations = [bounds, position]
        group.duration = CATransaction.animationDuration()
        group.timingFunction = CATransaction.animationTimingFunction()
        layer.add(group, forKey: "move")
    }

    func close() {
        guard !closed else { return }
        closed = true
        loading?.cancel()
        textField?.removeFromSuperview()
        textField = nil
        let done = onClose
        onClose = {}
        defer { done() }
        guard !reduceMotion(), window != nil, superview != nil else { removeFromSuperview(); return }
        // The picture shrinks back into its thumbnail when it is still the one opened, and the viewer fades; one
        // transaction, whose completion (on the main thread) takes the viewer off the pane.
        let chrome = subviews.filter { $0 !== backdrop && $0 !== dim }
        var ghost: CALayer?
        CATransaction.begin()
        CATransaction.setAnimationDuration(Self.closeDuration)
        CATransaction.setAnimationTimingFunction(Self.easeOut)
        CATransaction.setCompletionBlock { [weak self] in
            ghost?.removeFromSuperlayer()
            self?.removeFromSuperview()
        }
        if let origin, origin.index == gallery.index {
            let from = Self.fitted(CGSize(width: origin.image.width, height: origin.image.height), in: isComparing ? compare.frame : scroll.frame)
            let layer = Self.ghost(origin.image, frame: from)
            self.layer?.addSublayer(layer)
            for v in chrome { v.alphaValue = 0 }
            Self.move(layer, from: from, to: origin.rect)
            ghost = layer
        }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        fade.fillMode = .forwards
        fade.isRemovedOnCompletion = false
        for v in [backdrop, dim] + (ghost == nil ? chrome : []) { v.layer?.add(fade, forKey: "close") }
        CATransaction.commit()
    }
}

/// Keeps a picture smaller than the viewer in its middle (an `NSClipView` pins it to the top left).
@MainActor
private final class HomePictureClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let doc = documentView else { return rect }
        if rect.width > doc.frame.width { rect.origin.x = (doc.frame.width - rect.width) / 2 }
        if rect.height > doc.frame.height { rect.origin.y = (doc.frame.height - rect.height) / 2 }
        return rect
    }
}
