import AppKit

/// Native floating PDF controls. AppKit owns hit testing, menus, hover state,
/// and the macOS 26 glass effect without a hosted render tree.
@MainActor
final class FilePreviewPDFZoomChromeView: NSView {
    private let variant: FilePreviewPDFChromeStyleVariant

    init(
        chromeStyleVariant: FilePreviewPDFChromeStyleVariant,
        fileURL: URL?,
        zoomOut: @escaping () -> Void,
        actualSize: @escaping () -> Void,
        zoomIn: @escaping () -> Void,
        zoomToFit: @escaping () -> Void,
        rotateLeft: @escaping () -> Void,
        rotateRight: @escaping () -> Void,
        refresh: @escaping () -> Void
    ) {
        variant = chromeStyleVariant
        super.init(frame: .zero)

        let zoom = makeGroup([
            action("minus.magnifyingglass", label: String(localized: "filePreview.pdf.zoomOut", defaultValue: "Zoom Out"), closure: zoomOut),
            action("1.magnifyingglass", label: String(localized: "filePreview.pdf.actualSize", defaultValue: "Actual Size"), closure: actualSize),
            action("plus.magnifyingglass", label: String(localized: "filePreview.pdf.zoomIn", defaultValue: "Zoom In"), closure: zoomIn),
        ])
        let secondary = makeGroup([
            action("arrow.up.left.and.arrow.down.right", label: String(localized: "filePreview.pdf.zoomToFit", defaultValue: "Zoom to Fit"), closure: zoomToFit),
            action("rotate.left", label: String(localized: "filePreview.pdf.rotateLeft", defaultValue: "Rotate Left"), closure: rotateLeft),
            action("rotate.right", label: String(localized: "filePreview.pdf.rotateRight", defaultValue: "Rotate Right"), closure: rotateRight),
        ])

        var views: [NSView] = [zoom, secondary]
        if let fileURL {
            views.append(makeGroup([
                action("arrow.clockwise", label: String(localized: "filePreview.refresh", defaultValue: "Refresh"), closure: refresh),
            ]))
            views.append(makeGroup([FilePreviewExternalOpenButton(fileURL: fileURL, variant: variant)]))
        }
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        setAccessibilityLabel(String(localized: "filePreview.pdf.zoomControls", defaultValue: "Zoom Controls"))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func action(_ symbol: String, label: String, closure: @escaping () -> Void) -> NSView {
        FilePreviewChromeButton(systemName: symbol, label: label, variant: variant, action: closure)
    }

    private func makeGroup(_ controls: [NSView]) -> NSView {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 0
        for (index, control) in controls.enumerated() {
            if index > 0, variant != .systemControlGroup {
                let separator = NSBox()
                separator.boxType = .separator
                separator.translatesAutoresizingMaskIntoConstraints = false
                separator.heightAnchor.constraint(equalToConstant: 20).isActive = true
                separator.widthAnchor.constraint(equalToConstant: 1).isActive = true
                stack.addArrangedSubview(separator)
            }
            stack.addArrangedSubview(control)
        }
        return FilePreviewPDFChromeGroupView(variant: variant, content: stack)
    }
}

@MainActor
final class FilePreviewPDFChromeGroupView: NSView {
    private let variant: FilePreviewPDFChromeStyleVariant
    private let effectView: NSView?

    init(variant: FilePreviewPDFChromeStyleVariant, content: NSView) {
        self.variant = variant
        let effect: NSView?
        if variant == .liquidGlass, #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.style = .regular
            glass.cornerRadius = 20
            glass.contentView = content
            effect = glass
        } else if variant == .materialCapsule || variant == .thinOutline || variant == .liquidGlass {
            let visual = NSVisualEffectView()
            visual.material = variant == .thinOutline ? .underWindowBackground : .popover
            visual.blendingMode = .withinWindow
            visual.state = .active
            visual.wantsLayer = true
            visual.layer?.cornerRadius = 18
            visual.layer?.masksToBounds = true
            content.translatesAutoresizingMaskIntoConstraints = false
            visual.addSubview(content)
            NSLayoutConstraint.activate([
                content.leadingAnchor.constraint(equalTo: visual.leadingAnchor),
                content.trailingAnchor.constraint(equalTo: visual.trailingAnchor),
                content.topAnchor.constraint(equalTo: visual.topAnchor),
                content.bottomAnchor.constraint(equalTo: visual.bottomAnchor),
            ])
            effect = visual
        } else {
            effect = nil
        }
        effectView = effect
        super.init(frame: .zero)
        wantsLayer = true
        if variant == .borderedCapsule {
            layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.82).cgColor
            layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.55).cgColor
            layer?.borderWidth = 1
            layer?.cornerRadius = 18
        } else if variant == .plainToolbar || variant == .systemControlGroup {
            layer?.backgroundColor = NSColor.clear.cgColor
        }
        let installed = effect ?? content
        installed.translatesAutoresizingMaskIntoConstraints = false
        addSubview(installed)
        NSLayoutConstraint.activate([
            installed.leadingAnchor.constraint(equalTo: leadingAnchor),
            installed.trailingAnchor.constraint(equalTo: trailingAnchor),
            installed.topAnchor.constraint(equalTo: topAnchor),
            installed.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: variant == .liquidGlass ? 40 : 36),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

@MainActor
class FilePreviewChromeButton: NSButton {
    private let closure: () -> Void
    private var tracking: NSTrackingArea?
    private var hovered = false { didSet { updatePresentation() } }
    private let variant: FilePreviewPDFChromeStyleVariant

    init(systemName: String, label: String, variant: FilePreviewPDFChromeStyleVariant, action: @escaping () -> Void) {
        closure = action
        self.variant = variant
        super.init(frame: .zero)
        title = ""
        image = NSImage(systemSymbolName: systemName, accessibilityDescription: label)
        imagePosition = .imageOnly
        imageScaling = .scaleProportionallyDown
        toolTip = label
        setAccessibilityLabel(label)
        target = self
        self.action = #selector(invoke)
        bezelStyle = variant == .systemControlGroup ? .texturedRounded : .inline
        isBordered = variant == .systemControlGroup
        wantsLayer = true
        layer?.cornerRadius = 16
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: variant == .liquidGlass ? 42 : 38).isActive = true
        heightAnchor.constraint(equalToConstant: variant == .liquidGlass ? 40 : 36).isActive = true
        updatePresentation()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        let next = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self)
        addTrackingArea(next)
        tracking = next
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }

    override var isHighlighted: Bool {
        didSet { updatePresentation() }
    }

    private func updatePresentation() {
        contentTintColor = (hovered || isHighlighted) ? .labelColor : .secondaryLabelColor
        guard variant != .systemControlGroup else { return }
        let alpha: CGFloat = isHighlighted ? 0.24 : (hovered ? 0.14 : 0)
        layer?.backgroundColor = NSColor.white.withAlphaComponent(alpha).cgColor
    }

    @objc private func invoke() {
        closure()
    }
}

@MainActor
private final class FilePreviewExternalOpenButton: FilePreviewChromeButton {
    private let fileURL: URL

    init(fileURL: URL, variant: FilePreviewPDFChromeStyleVariant) {
        self.fileURL = fileURL
        super.init(
            systemName: "square.and.arrow.up",
            label: FileExternalOpenText.openExternally,
            variant: variant,
            action: {}
        )
        target = self
        action = #selector(showMenu)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func showMenu() {
        let applications = FileExternalOpenApplicationResolver.live.applications(for: fileURL)
        let primary = applications.first(where: \.isDefault) ?? applications.first
        let others = applications.filter { $0.id != primary?.id }
        let menu = FileExternalOpenMenuFactory.makeMenu(
            fileURL: fileURL,
            primaryApplication: primary,
            otherApplications: others
        )
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.maxY), in: self)
    }
}
