#if os(macOS)
import AppKit
import CmuxConversationCore
import ImageIO
import CmuxConversationGeometry

// Conversation backgrounds on macOS 26 Messages: a shared background drawn
// behind the transcript, the transcript's light or dark style derived from
// the background's luminance (ChatKit's contentDerivedUserInterfaceStyle),
// incoming bubbles that turn to a material over it, and the Edit Background
// picker. Every entrypoint (the transcript's context menu, View > Edit
// Background…, the details panel) calls `presentBackgroundPicker(from:)`.

/// A flipped view hosting a `ConversationBackdropLayer` (top-left geometry).
final class MacBackdropView: MacFlippedView {
    let backdrop = ConversationBackdropLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        layer?.addSublayer(backdrop)
        // The backdrop never takes clicks; the transcript above it does.
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        backdrop.frame = bounds
        CATransaction.commit()
    }

    /// Applies the system's Reduce Motion and Increase Contrast settings.
    func applyAccessibility() {
        let workspace = NSWorkspace.shared
        backdrop.isMotionPaused = workspace.accessibilityDisplayShouldReduceMotion
        backdrop.increasesContrast = workspace.accessibilityDisplayShouldIncreaseContrast
    }
}

/// How an incoming bubble fills over the conversation background.
enum MacBubbleBackdrop: Equatable {
    /// No background: the regular opaque gray.
    case none
    /// Over a background: a translucent material (Messages' material balloon).
    case material
    /// Over a background with Reduce Transparency: an opaque fill.
    case opaque

    /// The style for `background` under the current accessibility settings.
    static func style(for background: ConversationBackground?, reduceTransparency: Bool) -> MacBubbleBackdrop {
        guard background != nil else { return .none }
        return reduceTransparency ? .opaque : .material
    }
}

/// The transcript's appearance over a background: dark when white text
/// contrasts more (`prefersDarkContent`), nil (inherited) without one.
enum MacBackdropAppearance {
    static func name(for background: ConversationBackground?) -> NSAppearance.Name? {
        guard let background else { return nil }
        return background.prefersDarkContent ? .darkAqua : .aqua
    }
}

/// Decoded background photos, keyed by background id.
@MainActor
final class MacBackdropImageLoader {
    static let shared = MacBackdropImageLoader()
    private let cache = NSCache<NSString, CGImage>()

    func cached(_ background: ConversationBackground) -> CGImage? {
        cache.object(forKey: background.id as NSString)
    }

    func image(for background: ConversationBackground) async -> CGImage? {
        if let cached = cached(background) { return cached }
        guard let photo = background.photo else { return nil }
        let data: Data?
        if let local = photo.localData {
            data = local
        } else if let url = photo.url {
            data = try? await URLSession.shared.data(from: url).0
        } else {
            data = nil
        }
        guard let data, let image = NSImage(data: data)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        cache.setObject(image, forKey: background.id as NSString)
        return image
    }
}

extension MacConversationViewController {
    /// The incoming bubble style for the current background and settings.
    var bubbleBackdrop: MacBubbleBackdrop {
        MacBubbleBackdrop.style(for: store.background, reduceTransparency: NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency)
    }

    func installBackdrop() {
        backdropView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(backdropView, positioned: .below, relativeTo: scrollView)
        NSLayoutConstraint.activate([
            backdropView.topAnchor.constraint(equalTo: scrollView.topAnchor),
            backdropView.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            backdropView.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            backdropView.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor),
        ])
        backdropView.applyAccessibility()
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(accessibilityDisplayOptionsChanged),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil
        )
        updateBackdrop(animated: false)
    }

    @objc private func accessibilityDisplayOptionsChanged(_ note: Notification) {
        backdropView.applyAccessibility()
        updateBackdrop(animated: false)
    }

    /// Shows the store's background, derives the transcript's appearance from
    /// it and restyles visible incoming bubbles.
    func updateBackdrop(animated: Bool) {
        let background = store.background
        backdropView.isHidden = background == nil
        scrollView.drawsBackground = background == nil
        let appearance = MacBackdropAppearance.name(for: background).flatMap(NSAppearance.init(named:))
        if view.appearance?.name != appearance?.name { view.appearance = appearance }
        backgroundPhotoTask?.cancel()
        backgroundPhotoTask = nil
        if let background, background.kind == .photo {
            if let image = MacBackdropImageLoader.shared.cached(background) {
                backdropView.backdrop.set(background, image: image, animated: animated)
            } else {
                // Keep showing the previous photo of this background while it loads.
                let current = backdropView.backdrop.background?.id == background.id ? backdropView.backdrop.image : nil
                backdropView.backdrop.set(background, image: current, animated: animated)
                backgroundPhotoTask = Task { [weak self] in
                    let image = await MacBackdropImageLoader.shared.image(for: background)
                    guard let self, !Task.isCancelled, self.store.background?.id == background.id, let image else { return }
                    self.backdropView.backdrop.set(background, image: image, animated: true)
                }
            }
        } else {
            backdropView.backdrop.set(background, image: nil, animated: animated)
        }
        let style = bubbleBackdrop
        for index in 0..<rows.count {
            guard case .message = rows[index], let row = rowView(at: index), row.backdropStyle != style else { continue }
            row.backdropStyle = style
            row.refreshAppearance()
        }
    }

    // MARK: Picker

    /// Opens Edit Background: a popover from `anchor`, or a sheet on the
    /// window without one. The details panel's Backgrounds row calls this.
    public func presentBackgroundPicker(from anchor: NSView?) {
        guard store.supportsBackgrounds, store.info != nil else {
            NSSound.beep()
            return
        }
        if let open = backgroundPicker {
            open.view.window?.makeKeyAndOrderFront(nil)
            return
        }
        let picker = MacBackgroundPickerViewController(store: store)
        picker.onDone = { [weak self, weak picker] in
            guard let self, let picker else { return }
            if let popover = self.backgroundPopover {
                popover.performClose(nil)
            } else {
                self.dismiss(picker)
            }
            self.backgroundPicker = nil
            self.backgroundPopover = nil
        }
        backgroundPicker = picker
        if let anchor, anchor.window != nil {
            let popover = NSPopover()
            popover.behavior = .semitransient
            popover.contentViewController = picker
            popover.delegate = picker
            picker.onPopoverClosed = { [weak self] in
                self?.backgroundPicker = nil
                self?.backgroundPopover = nil
            }
            backgroundPopover = popover
            popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
        } else {
            presentAsSheet(picker)
        }
    }

    /// View > Edit Background… and the transcript context menu.
    @objc func editBackground(_ sender: Any?) {
        presentBackgroundPicker(from: nil)
    }

    /// The context menu over the transcript's empty area (ChatKit
    /// CONTEXT_EDIT_BACKGROUND).
    func backgroundContextMenu() -> NSMenu? {
        guard store.supportsBackgrounds, store.info != nil else { return nil }
        let menu = NSMenu()
        let item = MacClosureMenuItem(title: ConversationBackgroundStrings.editBackground) { [weak self] in
            self?.presentBackgroundPicker(from: nil)
        }
        item.image = NSImage(systemSymbolName: "photo.on.rectangle", accessibilityDescription: nil)
        menu.addItem(item)
        return menu
    }

    #if DEBUG
    /// Lab: `background state|picker|pick <look|none|#RRGGBB>|set|close`.
    func backgroundLabCommand(_ verb: String, _ argument: String) -> String? {
        guard verb == "background" else { return nil }
        let parts = argument.split(separator: " ").map(String.init)
        switch parts.first ?? "state" {
        case "state":
            let background = store.background
            let rowStyles = (0..<rows.count).compactMap { rowView(at: $0) }.filter { $0.model?.isOutgoing == false }.map { "\($0.backdropStyle)" }
            return [
                "kind=\(background?.kind.rawValue ?? "none")",
                "look=\(background?.look ?? "-")",
                String(format: "L=%.3f", background?.luminance ?? -1),
                "appearance=\(view.effectiveAppearance.isDarkMac ? "dark" : "light")",
                "drawsBackground=\(scrollView.drawsBackground)",
                "paused=\(backdropView.backdrop.isMotionPaused)",
                "contrast=\(backdropView.backdrop.increasesContrast)",
                "incoming=\(Set(rowStyles).sorted().joined(separator: ","))",
                "picker=\(backgroundPicker != nil)",
            ].joined(separator: " ")
        case "picker":
            presentBackgroundPicker(from: nil)
            return backgroundPicker != nil ? "ok" : "error unavailable"
        case "menu":
            return backgroundContextMenu()?.items.map(\.title).joined(separator: ",") ?? "error none"
        case "pick":
            guard let picker = backgroundPicker, parts.count > 1 else { return "error no picker" }
            return picker.labPick(parts[1]) ? "ok" : "error unknown look"
        case "set":
            guard let picker = backgroundPicker else { return "error no picker" }
            picker.commit()
            return "ok"
        case "close":
            backgroundPicker?.onDone?()
            return "ok"
        default:
            return "error usage background state|picker|menu|pick <look>|set|close"
        }
    }
    #endif
}

// MARK: - Picker model

/// What the picker will do on Set, independent of its views.
struct MacBackgroundPickerModel: Equatable {
    struct Photo: Equatable {
        var data: Data
        var mimeType: String
        var width: Int
        var height: Int
        var luminance: Double
    }

    enum Action: Equatable {
        case none
        case clear
        case set(ConversationBackgroundDraft)
        case setPhoto(Photo)
    }

    /// Nil is None.
    var kind: ConversationBackground.Kind?
    var lookID: String?
    /// A color picked from the color panel (overrides the look for `.color`).
    var customHex: String?
    var photo: Photo?
    /// The background being edited, so an unchanged Set does nothing.
    let current: ConversationBackground?

    init(current: ConversationBackground?) {
        self.current = current
        kind = current?.kind
        lookID = current?.look
        if current?.kind == .color, current?.look == nil, let first = current?.colors.first, current?.colors.count == 1 {
            customHex = first
        }
    }

    mutating func select(kind: ConversationBackground.Kind?) {
        guard kind != self.kind else { return }
        self.kind = kind
        customHex = nil
        if let kind, kind != .photo {
            lookID = ConversationBackgroundLook.looks(for: kind).first?.id
        } else {
            lookID = nil
        }
    }

    mutating func select(look: ConversationBackgroundLook) {
        kind = look.kind
        lookID = look.id
        customHex = nil
    }

    mutating func select(customHex hex: String) {
        kind = .color
        lookID = nil
        customHex = hex
    }

    /// The draft the preview shows (and Set applies); nil for None or a photo not yet chosen.
    var draft: ConversationBackgroundDraft? {
        switch kind {
        case nil, .photo?: return nil
        case let kind?:
            if kind == .color, let customHex { return .color(customHex) }
            guard let look = ConversationBackgroundLook.named(lookID), look.kind == kind else { return nil }
            return ConversationBackgroundDraft(look: look)
        }
    }

    /// The background the preview draws.
    var preview: ConversationBackground? {
        if kind == .photo {
            if let photo {
                return ConversationBackground(
                    id: "preview:photo:\(photo.data.count)", kind: .photo,
                    photo: .init(url: nil, width: photo.width, height: photo.height, localData: photo.data),
                    luminance: photo.luminance
                )
            }
            return current?.kind == .photo ? current : nil
        }
        return draft?.optimisticBackground(id: "preview:\(lookID ?? customHex ?? "")", setBy: nil)
    }

    var action: Action {
        switch kind {
        case nil:
            return current == nil ? .none : .clear
        case .photo?:
            if let photo { return .setPhoto(photo) }
            return .none
        default:
            guard let draft else { return .none }
            if let current, current.kind == draft.kind, current.colors == draft.colors, current.look == draft.look { return .none }
            return .set(draft)
        }
    }
}

// MARK: - Picker

/// Edit Background (macOS 26 Messages): None, Color, Photo, Sky, Water,
/// Aurora and Glitter, each with its looks, a live preview and Set.
final class MacBackgroundPickerViewController: NSViewController, NSPopoverDelegate {
    private let store: ConversationStore
    private(set) var model: MacBackgroundPickerModel
    var onDone: (() -> Void)?
    var onPopoverClosed: (() -> Void)?

    private let preview = MacBackdropView()
    private let previewIncoming = CAShapeLayer()
    private let previewOutgoing = CAShapeLayer()
    private let categories = NSSegmentedControl()
    private let swatchRow = NSStackView()
    private let colorWell = NSColorWell()
    private let choosePhoto = NSButton()
    private let setButton = NSButton()
    private var swatches: [(id: String, view: MacBackgroundSwatch)] = []
    private var previewImage: CGImage?
    private var photoTask: Task<Void, Never>?

    /// Segment order, as Messages lists the categories.
    static let kinds: [ConversationBackground.Kind?] = [nil, .color, .photo, .sky, .water, .aurora, .glitter]

    init(store: ConversationStore) {
        self.store = store
        model = MacBackgroundPickerModel(current: store.background)
        super.init(nibName: nil, bundle: nil)
        title = ConversationBackgroundStrings.editBackground
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 460, height: 470))
        view = root

        let titleLabel = NSTextField(labelWithString: ConversationBackgroundStrings.editBackground)
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.alignment = .center

        preview.wantsLayer = true
        preview.layer?.cornerRadius = 12
        preview.layer?.masksToBounds = true
        preview.layer?.borderWidth = 1
        preview.layer?.borderColor = NSColor.separatorColor.cgColor
        preview.layer?.addSublayer(previewIncoming)
        preview.layer?.addSublayer(previewOutgoing)
        preview.applyAccessibility()
        preview.setAccessibilityElement(true)
        preview.setAccessibilityRole(.image)
        preview.setAccessibilityIdentifier("conversation.background.preview")

        categories.segmentCount = Self.kinds.count
        for (index, kind) in Self.kinds.enumerated() {
            categories.setLabel(kind.map(ConversationBackgroundStrings.name) ?? ConversationBackgroundStrings.none, forSegment: index)
            categories.setWidth(0, forSegment: index)
        }
        categories.trackingMode = .selectOne
        categories.segmentDistribution = .fillEqually
        categories.target = self
        categories.action = #selector(categoryChanged)
        categories.setAccessibilityIdentifier("conversation.background.categories")

        swatchRow.orientation = .horizontal
        swatchRow.spacing = 8
        swatchRow.alignment = .centerY

        colorWell.target = self
        colorWell.action = #selector(customColorChanged)
        colorWell.setAccessibilityLabel(ConversationBackgroundStrings.backgroundColor)
        if #available(macOS 14.0, *) { colorWell.colorWellStyle = .minimal }

        choosePhoto.title = String(localized: "conversation.background.choosePhoto", defaultValue: "Choose Photo…", bundle: .module)
        choosePhoto.bezelStyle = .rounded
        choosePhoto.target = self
        choosePhoto.action = #selector(choosePhotoClicked)

        let cancel = NSButton(title: String(localized: "conversation.background.cancel", defaultValue: "Cancel", bundle: .module), target: self, action: #selector(cancelClicked))
        cancel.keyEquivalent = "\u{1b}"
        setButton.title = ConversationBackgroundStrings.set
        setButton.bezelStyle = .rounded
        setButton.keyEquivalent = "\r"
        setButton.target = self
        setButton.action = #selector(setClicked)
        setButton.setAccessibilityIdentifier("conversation.background.set")
        let buttons = NSStackView(views: [NSView(), cancel, setButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        let stack = NSStackView(views: [titleLabel, preview, categories, swatchRow, buttons])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            preview.widthAnchor.constraint(equalToConstant: 420),
            preview.heightAnchor.constraint(equalToConstant: 230),
            categories.widthAnchor.constraint(equalTo: preview.widthAnchor),
            buttons.widthAnchor.constraint(equalTo: preview.widthAnchor),
            swatchRow.heightAnchor.constraint(equalToConstant: 52),
        ])
        if let kind = model.kind, let index = Self.kinds.firstIndex(of: kind) {
            categories.selectedSegment = index
        } else {
            categories.selectedSegment = 0
        }
        rebuildSwatches()
        refreshPreview(animated: false)
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        layoutPreviewBubbles()
    }

    // MARK: Selection

    @objc private func categoryChanged() {
        model.select(kind: Self.kinds[max(0, categories.selectedSegment)])
        rebuildSwatches()
        refreshPreview(animated: true)
    }

    private func select(look: ConversationBackgroundLook) {
        model.select(look: look)
        updateSwatchSelection()
        refreshPreview(animated: true)
    }

    @objc private func customColorChanged() {
        guard let srgb = colorWell.color.usingColorSpace(.sRGB) else { return }
        model.select(customHex: ConversationBackground.hex(r: srgb.redComponent, g: srgb.greenComponent, b: srgb.blueComponent))
        updateSwatchSelection()
        refreshPreview(animated: true)
    }

    @objc private func choosePhotoClicked() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        // A standalone panel: the picker may itself be a sheet or a popover.
        panel.begin { [weak self, weak panel] response in
            guard response == .OK, let url = panel?.url else { return }
            self?.loadPhoto(url)
        }
    }

    private func loadPhoto(_ url: URL) {
        photoTask?.cancel()
        photoTask = Task { [weak self] in
            // Read and measure off the main thread; luminance travels with the background.
            let loaded = await Task.detached(priority: .userInitiated) { () -> MacBackgroundPickerModel.Photo? in
                guard let data = try? Data(contentsOf: url),
                      let source = CGImageSourceCreateWithData(data as CFData, nil),
                      let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
                      let luminance = ConversationBackground.luminance(of: image) else { return nil }
                let mime = url.pathExtension.lowercased() == "png" ? "image/png" : "image/jpeg"
                return MacBackgroundPickerModel.Photo(data: data, mimeType: mime, width: image.width, height: image.height, luminance: luminance)
            }.value
            guard let self, !Task.isCancelled else { return }
            guard let loaded else {
                NSSound.beep()
                return
            }
            self.model.photo = loaded
            self.previewImage = NSImage(data: loaded.data)?.cgImage(forProposedRect: nil, context: nil, hints: nil)
            self.refreshPreview(animated: true)
        }
    }

    @objc private func cancelClicked() { onDone?() }

    @objc private func setClicked() { commit() }

    /// Applies the selection through the store (the same path for every entrypoint).
    func commit() {
        let rejected: @MainActor (ConversationBackendError) -> Void = { _ in NSSound.beep() }
        switch model.action {
        case .none: break
        case .clear: store.setBackground(nil, rejected: rejected)
        case let .set(draft): store.setBackground(draft, rejected: rejected)
        case let .setPhoto(photo):
            store.setBackgroundPhoto(photo.data, mimeType: photo.mimeType, width: photo.width, height: photo.height, luminance: photo.luminance, rejected: rejected)
        }
        onDone?()
    }

    #if DEBUG
    /// Lab: select a look id, `none`, or `#RRGGBB`.
    func labPick(_ value: String) -> Bool {
        if value == "none" {
            categories.selectedSegment = 0
            categoryChanged()
            return true
        }
        if value.hasPrefix("#"), ConversationBackground.rgb(hex: value) != nil {
            categories.selectedSegment = Self.kinds.firstIndex(of: .color) ?? 1
            model.select(customHex: value.uppercased())
            rebuildSwatches()
            refreshPreview(animated: false)
            return true
        }
        guard let look = ConversationBackgroundLook.named(value) else { return false }
        categories.selectedSegment = Self.kinds.firstIndex(of: look.kind) ?? 0
        model.select(look: look)
        rebuildSwatches()
        refreshPreview(animated: false)
        return true
    }
    #endif

    // MARK: Views

    private func rebuildSwatches() {
        swatchRow.arrangedSubviews.forEach { $0.removeFromSuperview() }
        swatches = []
        switch model.kind {
        case nil:
            let label = NSTextField(labelWithString: ConversationBackgroundStrings.none)
            label.textColor = .secondaryLabelColor
            swatchRow.addArrangedSubview(label)
        case .photo?:
            swatchRow.addArrangedSubview(choosePhoto)
        case let kind?:
            let looks = ConversationBackgroundLook.looks(for: kind)
            // The color category fits its twelve looks at a smaller size.
            let side: CGFloat = looks.count > 6 ? 28 : 44
            for look in looks {
                let swatch = MacBackgroundSwatch(look: look, side: side)
                swatch.onSelect = { [weak self] in self?.select(look: look) }
                swatchRow.addArrangedSubview(swatch)
                swatches.append((look.id, swatch))
            }
            if kind == .color { swatchRow.addArrangedSubview(colorWell) }
        }
        updateSwatchSelection()
    }

    private func updateSwatchSelection() {
        for (id, swatch) in swatches { swatch.isSelected = id == model.lookID && model.customHex == nil }
        setButton.isEnabled = model.action != .none
    }

    private func refreshPreview(animated: Bool) {
        let background = model.preview
        let image = background?.kind == .photo ? (previewImage ?? (background.flatMap { MacBackdropImageLoader.shared.cached($0) })) : nil
        preview.backdrop.set(background, image: image, animated: animated)
        if background?.kind == .photo, image == nil, let background {
            photoTask = Task { [weak self] in
                guard let loaded = await MacBackdropImageLoader.shared.image(for: background) else { return }
                self?.previewImage = loaded
                self?.preview.backdrop.set(background, image: loaded, animated: true)
            }
        }
        preview.appearance = MacBackdropAppearance.name(for: background).flatMap(NSAppearance.init(named:))
        layoutPreviewBubbles()
        setButton.isEnabled = model.action != .none
    }

    /// Two sample bubbles show the contrast the transcript will get.
    private func layoutPreviewBubbles() {
        let bounds = preview.bounds
        guard bounds.width > 0 else { return }
        let t = MacConversationTheme.self
        let incoming = CGRect(x: 16, y: bounds.height - 96, width: 170, height: 32)
        let outgoing = CGRect(x: bounds.width - 16 - 140, y: bounds.height - 52, width: 140, height: 32)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        previewIncoming.path = ConversationBubbleGeometry.path(in: incoming, side: .leading, tail: true, radius: t.bubbleCornerRadius, tailWidth: t.tailWidth, tailDrop: t.tailDrop, style: .macOS)
        previewOutgoing.path = ConversationBubbleGeometry.path(in: outgoing, side: .trailing, tail: true, radius: t.bubbleCornerRadius, tailWidth: t.tailWidth, tailDrop: t.tailDrop, style: .macOS)
        let over = model.preview != nil
        let incomingFill = resolved(MacConversationTheme.incomingBubble, in: preview)
        previewIncoming.fillColor = over && !NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency ? incomingFill.copy(alpha: 0.72) : incomingFill
        previewOutgoing.fillColor = resolved(MacConversationTheme.outgoingBubble, in: preview)
        CATransaction.commit()
    }

    // MARK: NSPopoverDelegate

    func popoverDidClose(_ notification: Notification) {
        onPopoverClosed?()
    }
}

/// One look in the picker: a live miniature of the background.
final class MacBackgroundSwatch: MacFlippedView {
    let look: ConversationBackgroundLook
    var onSelect: (() -> Void)?
    var isSelected = false { didSet { updateRing() } }
    private let backdrop = MacBackdropView()
    private let side: CGFloat

    init(look: ConversationBackgroundLook, side: CGFloat) {
        self.look = look
        self.side = side
        super.init(frame: NSRect(x: 0, y: 0, width: side, height: side))
        backdrop.frame = bounds.insetBy(dx: 3, dy: 3)
        backdrop.layer?.cornerRadius = (side - 6) / 2
        backdrop.layer?.masksToBounds = true
        backdrop.applyAccessibility()
        backdrop.backdrop.set(ConversationBackgroundDraft(look: look).optimisticBackground(id: "swatch:\(look.id)", setBy: nil), image: nil, animated: false)
        addSubview(backdrop)
        layer?.cornerRadius = side / 2
        layer?.borderWidth = 2
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(ConversationBackgroundStrings.name(look))
        setAccessibilityIdentifier("conversation.background.look.\(look.id)")
        updateRing()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: side, height: side) }

    override func mouseDown(with event: NSEvent) { onSelect?() }

    override func accessibilityPerformPress() -> Bool {
        onSelect?()
        return true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateRing()
    }

    private func updateRing() {
        layer?.borderColor = isSelected ? resolved(.controlAccentColor, in: self) : NSColor.clear.cgColor
        setAccessibilityValue(isSelected ? "selected" : nil)
    }
}
#endif
