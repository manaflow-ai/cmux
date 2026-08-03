import AppKit
import CmuxFoundation

private enum PDFPreviewChromeDebugAction {
    case zoomOut
    case actualSize
    case zoomIn
    case zoomToFit
    case rotateLeft
    case rotateRight
    case refresh

    var title: String {
        switch self {
        case .zoomOut: String(localized: "filePreview.pdf.zoomOut", defaultValue: "Zoom Out")
        case .actualSize: String(localized: "filePreview.pdf.actualSize", defaultValue: "Actual Size")
        case .zoomIn: String(localized: "filePreview.pdf.zoomIn", defaultValue: "Zoom In")
        case .zoomToFit: String(localized: "filePreview.pdf.zoomToFit", defaultValue: "Zoom to Fit")
        case .rotateLeft: String(localized: "filePreview.pdf.rotateLeft", defaultValue: "Rotate Left")
        case .rotateRight: String(localized: "filePreview.pdf.rotateRight", defaultValue: "Rotate Right")
        case .refresh: String(localized: "filePreview.refresh", defaultValue: "Refresh")
        }
    }

    var systemName: String {
        switch self {
        case .zoomOut: "minus.magnifyingglass"
        case .actualSize: "1.magnifyingglass"
        case .zoomIn: "plus.magnifyingglass"
        case .zoomToFit: "arrow.up.left.and.arrow.down.right"
        case .rotateLeft: "rotate.left"
        case .rotateRight: "rotate.right"
        case .refresh: "arrow.clockwise"
        }
    }
}

@MainActor
private final class PDFPreviewChromeDebugModel {
    private(set) var lastActionTitle = ""
    private(set) var actionCount = 0
    var onChange: (() -> Void)?

    func record(_ action: PDFPreviewChromeDebugAction) {
        lastActionTitle = action.title
        actionCount += 1
        onChange?()
    }
}

@MainActor
private final class PDFPreviewChromeDebugView: NSView {
    private let model: PDFPreviewChromeDebugModel
    private let contentStack = NSStackView()
    private let statusLabel = NSTextField(wrappingLabelWithString: "")

    init(model: PDFPreviewChromeDebugModel) {
        self.model = model
        super.init(frame: .zero)
        setupView()
        model.onChange = { [weak self] in self?.updateStatus() }
        rebuildRows()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupView() {
        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 14
        contentStack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.documentView = contentStack
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(greaterThanOrEqualToConstant: 500),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 620),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            contentStack.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
        ])
    }

    private func rebuildRows() {
        contentStack.arrangedSubviews.forEach {
            contentStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        let heading = NSTextField(labelWithString: String(
            localized: "debug.pdfPreviewChrome.heading",
            defaultValue: "PDF Preview Chrome"
        ))
        heading.font = .systemFont(ofSize: 13, weight: .semibold)
        contentStack.addArrangedSubview(heading)

        let description = NSTextField(wrappingLabelWithString: String(
            localized: "debug.pdfPreviewChrome.description",
            defaultValue: "Choose the floating control style used by PDF previews."
        ))
        description.font = .systemFont(ofSize: 12)
        description.textColor = .secondaryLabelColor
        contentStack.addArrangedSubview(description)

        let referenceDescription = NSTextField(wrappingLabelWithString: String(
            localized: "debug.pdfPreviewChrome.toolbarReferenceDescription",
            defaultValue: "Use the buttons in this debug window's titlebar toolbar to test real NSToolbar hover and press feedback."
        ))
        referenceDescription.font = .systemFont(ofSize: 12)
        referenceDescription.textColor = .secondaryLabelColor
        statusLabel.font = .monospacedSystemFont(ofSize: 10.5, weight: .regular)
        statusLabel.textColor = .secondaryLabelColor
        let referenceStack = NSStackView(views: [referenceDescription, statusLabel])
        referenceStack.orientation = .vertical
        referenceStack.alignment = .leading
        referenceStack.spacing = 8
        contentStack.addArrangedSubview(group(
            String(localized: "debug.pdfPreviewChrome.toolbarReference", defaultValue: "Native Window Toolbar"),
            content: referenceStack
        ))
        updateStatus()

        for variant in FilePreviewPDFChromeStyleVariant.allCases {
            contentStack.addArrangedSubview(variantRow(variant))
        }

        let current = FilePreviewPDFChromeStyleVariant.current()
        let currentText = NSTextField(labelWithString: String(
            format: String(localized: "debug.pdfPreviewChrome.currentFormat", defaultValue: "Current: %@"),
            current.title
        ))
        currentText.font = .systemFont(ofSize: 11, weight: .medium)
        currentText.textColor = .secondaryLabelColor
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let footer = NSStackView(views: [
            currentText,
            spacer,
            button(String(localized: "debug.pdfPreviewChrome.copyConfig", defaultValue: "Copy Config"), selector: #selector(copyConfig)),
            button(String(localized: "debug.pdfPreviewChrome.resetToDefault", defaultValue: "Reset to Default"), selector: #selector(resetToDefault)),
        ])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 10
        footer.widthAnchor.constraint(equalTo: contentStack.widthAnchor, constant: -32).isActive = true
        contentStack.addArrangedSubview(footer)
    }

    private func variantRow(_ variant: FilePreviewPDFChromeStyleVariant) -> NSView {
        let selected = variant == FilePreviewPDFChromeStyleVariant.current()
        let check = NSImageView(image: NSImage(
            systemSymbolName: selected ? "checkmark.circle.fill" : "circle",
            accessibilityDescription: nil
        ) ?? NSImage())
        check.contentTintColor = selected ? .controlAccentColor : .secondaryLabelColor
        let title = NSTextField(labelWithString: variant.title)
        title.font = .systemFont(ofSize: 13, weight: .medium)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let use = PDFPreviewChromeVariantButton(variant: variant, selected: selected)
        use.target = self
        use.action = #selector(selectVariant(_:))
        let heading = NSStackView(views: [check, title, spacer, use])
        heading.orientation = .horizontal
        heading.alignment = .centerY
        heading.spacing = 10

        let sampleLabel = NSTextField(labelWithString: String(
            localized: "debug.pdfPreviewChrome.sampleLabel",
            defaultValue: "Sample"
        ))
        sampleLabel.font = .systemFont(ofSize: 11)
        sampleLabel.textColor = .secondaryLabelColor
        sampleLabel.widthAnchor.constraint(equalToConstant: 48).isActive = true
        let sample = FilePreviewPDFZoomChromeView(
            chromeStyleVariant: variant,
            fileURL: URL(fileURLWithPath: "/tmp/cmux-pdf-chrome-debug.pdf"),
            zoomOut: { [weak model] in model?.record(.zoomOut) },
            actualSize: { [weak model] in model?.record(.actualSize) },
            zoomIn: { [weak model] in model?.record(.zoomIn) },
            zoomToFit: { [weak model] in model?.record(.zoomToFit) },
            rotateLeft: { [weak model] in model?.record(.rotateLeft) },
            rotateRight: { [weak model] in model?.record(.rotateRight) },
            refresh: { [weak model] in model?.record(.refresh) }
        )
        let sampleRow = NSStackView(views: [sampleLabel, sample])
        sampleRow.orientation = .horizontal
        sampleRow.alignment = .centerY
        sampleRow.spacing = 8
        let stack = NSStackView(views: [heading, sampleRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        return group(variant.title, content: stack, showsTitle: false)
    }

    private func group(_ title: String, content: NSView, showsTitle: Bool = true) -> NSBox {
        let box = NSBox()
        box.title = showsTitle ? title : ""
        box.titlePosition = showsTitle ? .atTop : .noTitle
        content.translatesAutoresizingMaskIntoConstraints = false
        let wrapper = NSView()
        wrapper.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor, constant: 10),
            content.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor, constant: -10),
            content.topAnchor.constraint(equalTo: wrapper.topAnchor, constant: 10),
            content.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor, constant: -10),
        ])
        box.contentView = wrapper
        box.widthAnchor.constraint(equalTo: contentStack.widthAnchor, constant: -32).isActive = true
        return box
    }

    private func button(_ title: String, selector: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: selector)
        button.bezelStyle = .rounded
        return button
    }

    private func updateStatus() {
        if model.actionCount == 0 {
            statusLabel.stringValue = String(localized: "debug.pdfPreviewChrome.noActions", defaultValue: "No sample actions yet.")
        } else {
            statusLabel.stringValue = String(
                format: String(localized: "debug.pdfPreviewChrome.lastActionFormat", defaultValue: "Last action: %@ (%d)"),
                model.lastActionTitle,
                model.actionCount
            )
        }
    }

    @objc private func selectVariant(_ sender: PDFPreviewChromeVariantButton) {
        sender.variant.persist()
        rebuildRows()
    }

    @objc private func copyConfig() {
        let variant = FilePreviewPDFChromeStyleVariant.current()
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString("\(FilePreviewPDFChromeStyleVariant.defaultsKey)=\(variant.rawValue)", forType: .string)
    }

    @objc private func resetToDefault() {
        FilePreviewPDFChromeStyleVariant.liquidGlass.persist()
        rebuildRows()
    }
}

@MainActor
private final class PDFPreviewChromeVariantButton: NSButton {
    let variant: FilePreviewPDFChromeStyleVariant

    init(variant: FilePreviewPDFChromeStyleVariant, selected: Bool) {
        self.variant = variant
        super.init(frame: .zero)
        title = selected
            ? String(localized: "debug.pdfPreviewChrome.selected", defaultValue: "Selected")
            : String(localized: "debug.pdfPreviewChrome.use", defaultValue: "Use")
        bezelStyle = .rounded
        controlSize = .small
        isEnabled = !selected
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

final class PDFPreviewChromeDebugWindowController: ReleasingWindowController {
    static let shared = PDFPreviewChromeDebugWindowController()
    private static let zoomOutItemID = NSToolbarItem.Identifier("cmux.pdfPreviewChromeDebug.zoomOut")
    private static let actualSizeItemID = NSToolbarItem.Identifier("cmux.pdfPreviewChromeDebug.actualSize")
    private static let zoomInItemID = NSToolbarItem.Identifier("cmux.pdfPreviewChromeDebug.zoomIn")
    private static let zoomToFitItemID = NSToolbarItem.Identifier("cmux.pdfPreviewChromeDebug.zoomToFit")
    private static let rotateLeftItemID = NSToolbarItem.Identifier("cmux.pdfPreviewChromeDebug.rotateLeft")
    private static let rotateRightItemID = NSToolbarItem.Identifier("cmux.pdfPreviewChromeDebug.rotateRight")

    private let model = PDFPreviewChromeDebugModel()

    private override init() {
        super.init()
    }

    override func makeWindow() -> NSWindow {
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 660),
            styleMask: [.titled, .closable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        window.title = String(localized: "debug.pdfPreviewChrome.windowTitle", defaultValue: "PDF Preview Chrome")
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = false
        window.isMovableByWindowBackground = true
        window.identifier = NSUserInterfaceItemIdentifier("cmux.pdfPreviewChromeDebug")
        window.center()
        window.contentView = PDFPreviewChromeDebugView(model: model)
        AppDelegate.shared?.applyWindowDecorations(to: window)
        installToolbar(on: window)
        return window
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        showManagedWindow()
    }

    private func installToolbar(on window: NSWindow) {
        let toolbar = NSToolbar(identifier: NSToolbar.Identifier("cmux.pdfPreviewChromeDebug.toolbar"))
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.sizeMode = .regular
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        window.toolbarStyle = .unifiedCompact
    }

    @objc private func toolbarZoomOut(_ sender: Any?) { model.record(.zoomOut) }
    @objc private func toolbarActualSize(_ sender: Any?) { model.record(.actualSize) }
    @objc private func toolbarZoomIn(_ sender: Any?) { model.record(.zoomIn) }
    @objc private func toolbarZoomToFit(_ sender: Any?) { model.record(.zoomToFit) }
    @objc private func toolbarRotateLeft(_ sender: Any?) { model.record(.rotateLeft) }
    @objc private func toolbarRotateRight(_ sender: Any?) { model.record(.rotateRight) }

    private func makeToolbarItem(
        identifier: NSToolbarItem.Identifier,
        action: PDFPreviewChromeDebugAction,
        selector: Selector
    ) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = action.title
        item.paletteLabel = action.title
        item.toolTip = action.title
        item.image = NSImage(systemSymbolName: action.systemName, accessibilityDescription: action.title)
        item.target = self
        item.action = selector
        item.isBordered = true
        return item
    }
}

extension PDFPreviewChromeDebugWindowController: NSToolbarDelegate {
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, Self.zoomOutItemID, Self.actualSizeItemID, Self.zoomInItemID, Self.zoomToFitItemID, Self.rotateLeftItemID, Self.rotateRightItemID]
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarAllowedItemIdentifiers(toolbar)
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        switch itemIdentifier {
        case Self.zoomOutItemID: makeToolbarItem(identifier: itemIdentifier, action: .zoomOut, selector: #selector(toolbarZoomOut(_:)))
        case Self.actualSizeItemID: makeToolbarItem(identifier: itemIdentifier, action: .actualSize, selector: #selector(toolbarActualSize(_:)))
        case Self.zoomInItemID: makeToolbarItem(identifier: itemIdentifier, action: .zoomIn, selector: #selector(toolbarZoomIn(_:)))
        case Self.zoomToFitItemID: makeToolbarItem(identifier: itemIdentifier, action: .zoomToFit, selector: #selector(toolbarZoomToFit(_:)))
        case Self.rotateLeftItemID: makeToolbarItem(identifier: itemIdentifier, action: .rotateLeft, selector: #selector(toolbarRotateLeft(_:)))
        case Self.rotateRightItemID: makeToolbarItem(identifier: itemIdentifier, action: .rotateRight, selector: #selector(toolbarRotateRight(_:)))
        default: nil
        }
    }
}
