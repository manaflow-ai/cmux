import AppKit
import ImageIO
import UniformTypeIdentifiers

/// cmux: the large picture viewer over a Chief chat pane (the user, 2026-11-05, on a Before|After table: "i want
/// to be able to expand and annotate"). A click on a picture in a table card (or a picture bubble) opens it: the
/// pane dims and blurs under it, it fits the pane and zooms (pinch, Command-plus and -minus, Command-0 to fit, a
/// double-click for its own size) and pans (scroll, or drag with Move). The arrow keys and the side buttons step
/// through the table's pictures; C (or Compare) shows the row's Before and After with a slider. The tools mark it
/// up (arrow, box, pen, text; Command-Z undoes); Send in Chat hands the marked picture to the message box, Copy
/// and Save keep it. Esc leaves the words being typed, then the comparison, then closes. Like
/// ``HomeVideoViewer`` it stays inside its pane.
@MainActor
final class HomePictureViewer: NSView {
    /// What a key does in the viewer (``handle(_:)``; `keyDown` maps the real keys to it).
    enum Key: Equatable, Sendable {
        case left, right, escape, compare, undo, zoomIn, zoomOut, fit
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
    private let spinner = NSProgressIndicator(frame: .zero)
    private let closeButton = NSButton(frame: .zero)
    private let previousButton = NSButton(frame: .zero)
    private let nextButton = NSButton(frame: .zero)
    private let bar = NSVisualEffectView(frame: .zero)
    private let tools = NSSegmentedControl(frame: .zero)
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
        spinner.style = .spinning
        spinner.controlSize = .regular
        spinner.isDisplayedWhenStopped = false
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
        let undo = barButton("arrow.uturn.backward", CmuxStrings.pictureUndo, #selector(undoClicked))
        undoButton = undo
        let cmp = barButton("rectangle.split.2x1", CmuxStrings.pictureCompare, #selector(compareClicked))
        compareButton = cmp
        barButtons = [undo, cmp,
                      barButton("doc.on.doc", CmuxStrings.pictureCopy, #selector(copyClicked)),
                      barButton("square.and.arrow.down", CmuxStrings.pictureSave, #selector(saveClicked)),
                      barButton("arrowshape.turn.up.left.fill", CmuxStrings.pictureReply, #selector(replyClicked))]
        for b in barButtons { bar.addSubview(b) }

        for v in [backdrop, dim, scroll, compare, status, spinner, titleLabel, counterLabel, previousButton, nextButton, bar, closeButton] as [NSView] {
            addSubview(v)
        }
        setAccessibilityRole(.group)
        setAccessibilityLabel(CmuxStrings.pictureViewer)
        show()
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
        tools.isEnabled = !isComparing
        if isComparing { showCompare() }
        compareButton?.state = isComparing ? .on : .off
        compareButton?.contentTintColor = isComparing ? .controlAccentColor : NSColor.white.withAlphaComponent(0.85)
    }

    override func layout() {
        super.layout()
        backdrop.frame = bounds
        dim.frame = bounds
        let top: CGFloat = 44, bottom: CGFloat = 64, side: CGFloat = gallery.items.count > 1 ? 56 : 20
        let area = CGRect(x: side, y: top, width: max(0, bounds.width - 2 * side), height: max(0, bounds.height - top - bottom))
        scroll.frame = area
        compare.frame = area
        titleLabel.frame = CGRect(x: 16, y: 14, width: max(0, bounds.width - 180), height: 18)
        counterLabel.frame = CGRect(x: bounds.maxX - 150, y: 15, width: 100, height: 16)
        counterLabel.alignment = .right
        closeButton.frame = CGRect(x: bounds.maxX - 38, y: 10, width: 26, height: 26)
        previousButton.frame = CGRect(x: 12, y: bounds.midY - 18, width: 36, height: 36)
        nextButton.frame = CGRect(x: bounds.maxX - 48, y: bounds.midY - 18, width: 36, height: 36)
        spinner.frame = CGRect(x: bounds.midX - 16, y: bounds.midY - 16, width: 32, height: 32)
        status.frame = CGRect(x: 20, y: bounds.midY - 10, width: max(0, bounds.width - 40), height: 20)
        let toolsWidth = tools.fittingSize.width
        let buttonWidth: CGFloat = 32
        let barWidth = 12 + toolsWidth + 12 + CGFloat(barButtons.count) * buttonWidth + 8
        bar.frame = CGRect(x: (bounds.midX - barWidth / 2).rounded(), y: bounds.maxY - 50, width: barWidth, height: 38)
        tools.frame = CGRect(x: 12, y: (38 - tools.fittingSize.height) / 2, width: toolsWidth, height: tools.fittingSize.height)
        var x = tools.frame.maxX + 12
        for b in barButtons {
            b.frame = CGRect(x: x, y: 5, width: buttonWidth, height: 28)
            x += buttonWidth
        }
        if let textField {
            textField.frame.size.width = max(160, min(320, bounds.width - textField.frame.minX - 20))
        }
    }

    // MARK: Keys

    /// Does what `key` does in the viewer; false when it does nothing here.
    @discardableResult
    func handle(_ key: Key) -> Bool {
        switch key {
        case .escape:
            if textField != nil { endText(commit: false); return true }
            if isComparing { setComparing(false); return true }
            close()
        case .left, .right:
            let next = gallery.moved(by: key == .left ? -1 : 1)
            guard next.index != gallery.index else { return true }
            endText(commit: true)
            gallery = next
            show()
        case .compare: setComparing(!isComparing)
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
        case (_, "z") where command: .undo
        case (_, "="), (_, "+"): command ? .zoomIn : nil
        case (_, "-") where command: .zoomOut
        case (_, "0") where command: .fit
        case (_, "c") where command: nil
        case (_, "c"): .compare
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
    @objc private func compareClicked() { handle(.compare) }
    @objc private func previousClicked() { handle(.left) }
    @objc private func nextClicked() { handle(.right) }
    @objc private func closeClicked() { close() }
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

    func close() {
        guard !closed else { return }
        closed = true
        loading?.cancel()
        textField?.removeFromSuperview()
        textField = nil
        removeFromSuperview()
        let done = onClose
        onClose = {}
        done()
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
