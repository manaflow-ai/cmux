public import AppKit
public import Foundation
internal import PDFKit
internal import SwiftUI
internal import CmuxFoundation
internal import CMUXDebugLog

/// The native PDF file-preview surface: an `NSSplitView` pairing a sidebar
/// (thumbnail strip or table-of-contents outline) with the magnifying PDF canvas,
/// plus floating chrome (sidebar/zoom controls) hosted above the canvas.
///
/// It owns the viewport/resize state machine that keeps the visible page stable
/// across sidebar resizes, zoom, rotation, and page navigation, and it acts as the
/// split-view delegate and the outline `NSOutlineView` data source/delegate. All
/// app couplings (focus coordination, keyboard-focus resync, and the localized
/// "Open with…" chrome menu) route through ``FilePreviewNativeHosting``; the host
/// is injected after construction via ``setHost(_:)``.
public final class FilePreviewPDFContainerView: NSView, NSSplitViewDelegate, NSOutlineViewDataSource, NSOutlineViewDelegate {
    private enum Metrics {
        static let defaultSidebarWidth = FilePreviewPDFSizing.defaultSidebarWidth
        static let minimumSidebarWidth = FilePreviewPDFSizing.minimumSidebarWidth
        static let maximumSidebarWidth = FilePreviewPDFSizing.maximumSidebarWidth
        static let floatingChromeHeight: CGFloat = 40
        static let floatingControlsWidth: CGFloat = 344
        static let floatingChromeCornerRadius: CGFloat = 20
    }

    private let splitView = NSSplitView()
    private let sidebarHost = NSVisualEffectView()
    private let contentHost = NSView()
    private let chromeHost = FilePreviewPDFChromeHostView()
    private let pdfView = FilePreviewMagnifyingPDFView()
    private let thumbnailView = FilePreviewPDFThumbnailSidebarView()
    private let outlineScrollView = NSScrollView()
    private let outlineView = FilePreviewPDFOutlineView()
    private let outlinePlaceholder = NSTextField(wrappingLabelWithString: "")
    private let sidebarChromeHost = FilePreviewPDFChromeHostingView(rootView: AnyView(EmptyView()))
    private let zoomChromeHost = FilePreviewPDFChromeHostingView(rootView: AnyView(EmptyView()))
    private let titleLabel = NSTextField(labelWithString: "")
    private let pageLabel = NSTextField(labelWithString: "")
    private weak var host: (any FilePreviewNativeHosting)?
    private var currentURL: URL?
    private var outlineRoot: PDFOutline?
    private var sidebarMode: FilePreviewPDFSidebarMode = .thumbnails
    private var displayMode: FilePreviewPDFDisplayMode = .continuousScroll
    private var isSidebarVisible = true
    private var chromeStyleVariant = FilePreviewPDFChromeStyleVariant.current()
    private var didSetInitialSidebarWidth = false
    private var lastSidebarWidth = Metrics.defaultSidebarWidth
    private var didUserResizeSidebar = false
    private var isApplyingSidebarWidth = false
    private var pendingSidebarResizeSnapshot: FilePreviewPDFViewportSnapshot?
    private var suppressPDFPageChangeNotifications = false
    private var pdfResizeSequence = 0
    private var activePDFResizeID: Int?
    private var activePDFRegion: FilePreviewPanelFocusIntent?
    private weak var observedPDFClipView: NSClipView?
    private var rotationAccumulator: CGFloat = 0
    private var previewBackgroundColor = NSColor.textBackgroundColor
    private var drawsPreviewBackground = true
    private var lastAppliedPDFScrollBackgroundAppearance: PDFScrollBackgroundAppearance?
    private static let documentLoadQueue = DispatchQueue(
        label: "com.cmux.file-preview.pdf-document-load",
        qos: .userInitiated
    )

    private struct PDFScrollBackgroundAppearance {
        let hostIdentifiers: Set<ObjectIdentifier>
        let backgroundColor: NSColor
        let drawsBackground: Bool

        func matches(_ other: PDFScrollBackgroundAppearance) -> Bool {
            hostIdentifiers == other.hostIdentifiers
                && drawsBackground == other.drawsBackground
                && backgroundColor.isEqual(other.backgroundColor)
        }
    }

    override public init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupView()
    }

    public required init?(coder: NSCoder) {
        nil
    }

    deinit {
        removePDFScrollObserver()
        NotificationCenter.default.removeObserver(self)
    }

    override public func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        registerFocusEndpoint()
        updatePDFThumbnailSelectionFocus()
    }

    override public func layout() {
        super.layout()
        applyBackgroundAppearance()
        if !didSetInitialSidebarWidth, bounds.width > 0 {
            didSetInitialSidebarWidth = true
            let initialWidth = clampedSidebarWidth(lastSidebarWidth)
            lastSidebarWidth = initialWidth
            splitView.setPosition(initialWidth, ofDividerAt: 0)
            splitView.adjustSubviews()
            refreshPDFSmartFitWithoutViewportRestore()
        }
        layoutFloatingChrome()
    }

    override public func hitTest(_ point: NSPoint) -> NSView? {
        let chromePoint = convert(point, to: chromeHost)
        if let chromeHit = chromeHost.hitTest(chromePoint) {
            return chromeHit
        }
        return super.hitTest(point)
    }

    public func setHost(_ host: any FilePreviewNativeHosting) {
        self.host = host
        registerFocusEndpoint()
    }

    public func close() {
        removeFromSuperview()
        removePDFScrollObserver()
        NotificationCenter.default.removeObserver(self)
        pdfView.document = nil
        thumbnailView.setDocument(nil)
        outlineRoot = nil
        currentURL = nil
        host = nil
    }

    public func setBackgroundAppearance(backgroundColor: NSColor, drawsBackground: Bool) {
        guard previewBackgroundColor != backgroundColor || drawsPreviewBackground != drawsBackground else { return }
        previewBackgroundColor = backgroundColor
        drawsPreviewBackground = drawsBackground
        invalidatePDFScrollBackgroundAppearance()
        applyBackgroundAppearance()
    }

    public func setURL(_ url: URL) {
        guard currentURL != url else {
            applyPreferredSidebarWidthIfNeeded()
            updatePageControls()
            refreshPDFSmartFitPreservingVisibleTop()
            return
        }
        currentURL = url
        updateChromeRootViews()
        pdfView.document = nil
        thumbnailView.setDocument(nil)
        outlineRoot = nil
        titleLabel.stringValue = url.lastPathComponent
        rotationAccumulator = 0
        didUserResizeSidebar = false
        lastSidebarWidth = preferredSidebarWidthForCurrentMode()
        pdfView.autoScales = true
        applyDisplayMode()
        outlineView.reloadData()
        updateSidebarContent()
        applyPreferredSidebarWidthIfNeeded()
        updatePageControls()
        refreshPDFSmartFitWithoutViewportRestore()

        let loadURL = url
        Self.documentLoadQueue.async { [weak self] in
            let document = PDFDocument(url: loadURL)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.currentURL == loadURL else { return }
                self.applyLoadedPDFDocument(document, for: loadURL)
            }
        }
    }

    private func applyLoadedPDFDocument(_ document: PDFDocument?, for url: URL) {
        pdfView.document = document
        thumbnailView.setDocument(document)
        outlineRoot = document?.outlineRoot
        titleLabel.stringValue = url.lastPathComponent
        pdfView.autoScales = true
        applyDisplayMode()
        updatePDFScrollObserver()
        outlineView.reloadData()
        updateSidebarContent()
        applyPreferredSidebarWidthIfNeeded()
        updatePageControls(scrollThumbnailToVisible: false)
        invalidatePDFScrollBackgroundAppearance()
        applyBackgroundAppearance()
        refreshPDFSmartFitWithoutViewportRestore()
    }

    private func setupView() {
        translatesAutoresizingMaskIntoConstraints = false
        setupSplitView()
        setupSidebar()
        setupPDFView()
        setupFloatingChrome()
        applyBackgroundAppearance()

        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        pdfView.displaysPageBreaks = true
        pdfView.minScaleFactor = 0.1
        pdfView.maxScaleFactor = 8.0
        pdfView.onMagnify = { [weak self] event in
            let factor = 1.0 + event.magnification
            self?.zoomPDF(with: event, factor: factor)
        }
        pdfView.onScrollZoom = { [weak self] event in
            self?.zoomPDF(with: event, factor: FilePreviewZoomInteraction.standard.zoomFactor(forScroll: event))
        }
        pdfView.onScroll = { [weak self] in
            self?.updatePageControls()
        }
        pdfView.onSmartMagnify = { [weak self] in
            self?.togglePDFSmartZoom()
        }
        pdfView.onRotate = { [weak self] event in
            self?.rotatePDF(with: event)
        }
        pdfView.onSwipe = { [weak self] event in
            self?.swipePDF(with: event)
        }
        updatePDFScrollObserver()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(pdfPageChanged),
            name: Notification.Name.PDFViewPageChanged,
            object: pdfView
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(pdfChromeStyleChanged),
            name: .filePreviewPDFChromeStyleDidChange,
            object: nil
        )
        registerFocusEndpoint()
    }

    private func setupSplitView() {
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.delegate = self
        splitView.translatesAutoresizingMaskIntoConstraints = false
        splitView.addArrangedSubview(sidebarHost)
        splitView.addArrangedSubview(contentHost)
        splitView.setHoldingPriority(.defaultHigh, forSubviewAt: 0)
        splitView.setHoldingPriority(.defaultLow, forSubviewAt: 1)
        addSubview(splitView)

        NSLayoutConstraint.activate([
            splitView.topAnchor.constraint(equalTo: topAnchor),
            splitView.leadingAnchor.constraint(equalTo: leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: trailingAnchor),
            splitView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    private func setupSidebar() {
        sidebarHost.material = .sidebar
        sidebarHost.blendingMode = .withinWindow
        sidebarHost.state = .active

        thumbnailView.onSelectPage = { [weak self] page in
            self?.setActivePDFRegion(.pdfThumbnails)
            self?.goToPDFPage(page, scrollThumbnailToVisible: false)
        }
        thumbnailView.onFocusChanged = { [weak self] isActive in
            self?.setActivePDFRegion(isActive ? .pdfThumbnails : nil)
        }
        thumbnailView.onPageNavigation = { [weak self] delta in
            self?.navigatePDFPage(by: delta)
        }
        thumbnailView.translatesAutoresizingMaskIntoConstraints = false

        let outlineColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("filePreviewPDFOutline"))
        outlineColumn.title = String(localized: "filePreview.pdf.tableOfContents", defaultValue: "Table of Contents")
        outlineView.addTableColumn(outlineColumn)
        outlineView.outlineTableColumn = outlineColumn
        outlineView.headerView = nil
        outlineView.rowSizeStyle = .medium
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.onFocusChanged = { [weak self] isActive in
            self?.setActivePDFRegion(isActive ? .pdfOutline : nil)
        }
        outlineView.translatesAutoresizingMaskIntoConstraints = false

        outlineScrollView.hasVerticalScroller = true
        outlineScrollView.autohidesScrollers = true
        outlineScrollView.borderType = .noBorder
        outlineScrollView.drawsBackground = false
        outlineScrollView.documentView = outlineView
        outlineScrollView.translatesAutoresizingMaskIntoConstraints = false

        outlinePlaceholder.stringValue = String(
            localized: "filePreview.pdf.noTableOfContents",
            defaultValue: "No table of contents"
        )
        outlinePlaceholder.alignment = .center
        outlinePlaceholder.textColor = .secondaryLabelColor
        outlinePlaceholder.translatesAutoresizingMaskIntoConstraints = false

        sidebarHost.addSubview(thumbnailView)
        sidebarHost.addSubview(outlineScrollView)
        sidebarHost.addSubview(outlinePlaceholder)

        NSLayoutConstraint.activate([
            thumbnailView.topAnchor.constraint(equalTo: sidebarHost.topAnchor),
            thumbnailView.leadingAnchor.constraint(equalTo: sidebarHost.leadingAnchor),
            thumbnailView.trailingAnchor.constraint(equalTo: sidebarHost.trailingAnchor),
            thumbnailView.bottomAnchor.constraint(equalTo: sidebarHost.bottomAnchor),
            outlineScrollView.topAnchor.constraint(equalTo: sidebarHost.topAnchor),
            outlineScrollView.leadingAnchor.constraint(equalTo: sidebarHost.leadingAnchor),
            outlineScrollView.trailingAnchor.constraint(equalTo: sidebarHost.trailingAnchor),
            outlineScrollView.bottomAnchor.constraint(equalTo: sidebarHost.bottomAnchor),
            outlinePlaceholder.centerXAnchor.constraint(equalTo: sidebarHost.centerXAnchor),
            outlinePlaceholder.centerYAnchor.constraint(equalTo: sidebarHost.centerYAnchor),
            outlinePlaceholder.leadingAnchor.constraint(greaterThanOrEqualTo: sidebarHost.leadingAnchor, constant: 16),
            outlinePlaceholder.trailingAnchor.constraint(lessThanOrEqualTo: sidebarHost.trailingAnchor, constant: -16),
        ])
    }

    private func setupPDFView() {
        contentHost.wantsLayer = true
        pdfView.translatesAutoresizingMaskIntoConstraints = false
        pdfView.onFocusChanged = { [weak self] isActive in
            self?.setActivePDFRegion(isActive ? .pdfCanvas : nil)
        }
        contentHost.addSubview(pdfView)
        NSLayoutConstraint.activate([
            pdfView.topAnchor.constraint(equalTo: contentHost.topAnchor),
            pdfView.leadingAnchor.constraint(equalTo: contentHost.leadingAnchor),
            pdfView.trailingAnchor.constraint(equalTo: contentHost.trailingAnchor),
            pdfView.bottomAnchor.constraint(equalTo: contentHost.bottomAnchor),
        ])
    }

    private func applyBackgroundAppearance() {
        FilePreviewNativeBackground.applyRootLayer(
            to: self,
            backgroundColor: previewBackgroundColor,
            drawsBackground: drawsPreviewBackground
        )
        FilePreviewNativeBackground.applyRootLayer(
            to: contentHost,
            backgroundColor: previewBackgroundColor,
            drawsBackground: drawsPreviewBackground
        )
        let resolvedBackgroundColor = FilePreviewNativeBackground.resolvedColor(
            backgroundColor: previewBackgroundColor,
            drawsBackground: drawsPreviewBackground
        )
        pdfView.backgroundColor = resolvedBackgroundColor
        let scrollBackgroundAppearance = currentPDFScrollBackgroundAppearance(
            resolvedBackgroundColor: resolvedBackgroundColor
        )
        guard shouldApplyPDFScrollBackground(scrollBackgroundAppearance) else { return }
        FilePreviewNativeBackground.applyScrollBackgrounds(
            in: pdfView,
            backgroundColor: previewBackgroundColor,
            drawsBackground: drawsPreviewBackground
        )
        lastAppliedPDFScrollBackgroundAppearance = scrollBackgroundAppearance
    }

    private func invalidatePDFScrollBackgroundAppearance() {
        lastAppliedPDFScrollBackgroundAppearance = nil
    }

    private func currentPDFScrollBackgroundAppearance(
        resolvedBackgroundColor: NSColor
    ) -> PDFScrollBackgroundAppearance {
        var hostIdentifiers = FilePreviewNativeBackground.scrollBackgroundHostIdentifiers(in: pdfView)
        if hostIdentifiers.isEmpty {
            hostIdentifiers.insert(ObjectIdentifier(pdfView))
        }
        return PDFScrollBackgroundAppearance(
            hostIdentifiers: hostIdentifiers,
            backgroundColor: resolvedBackgroundColor,
            drawsBackground: drawsPreviewBackground
        )
    }

    private func shouldApplyPDFScrollBackground(_ appearance: PDFScrollBackgroundAppearance) -> Bool {
        guard let lastAppliedPDFScrollBackgroundAppearance else { return true }
        return !lastAppliedPDFScrollBackgroundAppearance.matches(appearance)
    }

    private func setupFloatingChrome() {
        chromeHost.frame = bounds.width > 0 && bounds.height > 0
            ? bounds
            : NSRect(x: 0, y: 0, width: 480, height: 320)
        chromeHost.autoresizingMask = []
        addSubview(chromeHost, positioned: .above, relativeTo: splitView)

        sidebarChromeHost.translatesAutoresizingMaskIntoConstraints = false
        zoomChromeHost.translatesAutoresizingMaskIntoConstraints = false
        updateChromeRootViews()

        chromeHost.addSubview(sidebarChromeHost)
        chromeHost.addSubview(zoomChromeHost)
        chromeHost.interactiveOverlayViews = [sidebarChromeHost, zoomChromeHost]

        titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        pageLabel.font = .systemFont(ofSize: 11)
        pageLabel.textColor = .secondaryLabelColor
        pageLabel.lineBreakMode = .byTruncatingTail

        let titleStack = NSStackView(views: [titleLabel, pageLabel])
        titleStack.orientation = .vertical
        titleStack.alignment = .leading
        titleStack.spacing = 1
        titleStack.translatesAutoresizingMaskIntoConstraints = false
        chromeHost.addSubview(titleStack)

        let zoomWidthConstraint = zoomChromeHost.widthAnchor.constraint(equalToConstant: Metrics.floatingControlsWidth)
        zoomWidthConstraint.priority = .defaultHigh

        NSLayoutConstraint.activate([
            sidebarChromeHost.topAnchor.constraint(equalTo: chromeHost.topAnchor, constant: 10),
            sidebarChromeHost.leadingAnchor.constraint(equalTo: chromeHost.leadingAnchor, constant: 10),
            sidebarChromeHost.widthAnchor.constraint(equalToConstant: 68),
            sidebarChromeHost.heightAnchor.constraint(equalToConstant: Metrics.floatingChromeHeight),

            zoomChromeHost.topAnchor.constraint(equalTo: chromeHost.topAnchor, constant: 10),
            zoomChromeHost.trailingAnchor.constraint(equalTo: chromeHost.trailingAnchor, constant: -10),
            zoomWidthConstraint,
            zoomChromeHost.heightAnchor.constraint(equalToConstant: Metrics.floatingChromeHeight),

            titleStack.leadingAnchor.constraint(equalTo: sidebarChromeHost.trailingAnchor, constant: 12),
            titleStack.centerYAnchor.constraint(equalTo: sidebarChromeHost.centerYAnchor),
            titleStack.trailingAnchor.constraint(lessThanOrEqualTo: zoomChromeHost.leadingAnchor, constant: -12),
        ])
    }

    private func layoutFloatingChrome() {
        let contentFrame = contentHost.convert(contentHost.bounds, to: self)
        guard contentFrame.width > 0, contentFrame.height > 0 else { return }
        if chromeHost.frame != contentFrame {
            chromeHost.frame = contentFrame
        }
        chromeHost.needsLayout = true
    }

    private func updateChromeRootViews() {
        sidebarChromeHost.rootView = AnyView(FilePreviewPDFSidebarChromeView(
            isSidebarVisible: isSidebarVisible,
            sidebarMode: sidebarMode,
            displayMode: displayMode,
            chromeStyleVariant: chromeStyleVariant,
            strings: FilePreviewPDFSidebarChromeStrings(
                sidebarOptions: String(localized: "filePreview.pdf.sidebarOptions", defaultValue: "Sidebar Options"),
                hideSidebar: String(localized: "filePreview.pdf.hideSidebar", defaultValue: "Hide Sidebar"),
                showSidebar: String(localized: "filePreview.pdf.showSidebar", defaultValue: "Show Sidebar"),
                thumbnails: String(localized: "filePreview.pdf.thumbnails", defaultValue: "Thumbnails"),
                tableOfContents: String(localized: "filePreview.pdf.tableOfContents", defaultValue: "Table of Contents"),
                continuousScroll: String(localized: "filePreview.pdf.continuousScroll", defaultValue: "Continuous Scroll"),
                singlePage: String(localized: "filePreview.pdf.singlePage", defaultValue: "Single Page"),
                twoPages: String(localized: "filePreview.pdf.twoPages", defaultValue: "Two Pages")
            ),
            toggleSidebar: { [weak self] in self?.toggleSidebar() },
            selectThumbnails: { [weak self] in self?.selectThumbnailSidebar() },
            selectTableOfContents: { [weak self] in self?.selectTableOfContentsSidebar() },
            selectContinuousScroll: { [weak self] in self?.selectContinuousScroll() },
            selectSinglePage: { [weak self] in self?.selectSinglePage() },
            selectTwoPages: { [weak self] in self?.selectTwoPages() }
        ))
        zoomChromeHost.rootView = AnyView(FilePreviewPDFZoomChromeView(
            chromeStyleVariant: chromeStyleVariant,
            strings: FilePreviewPDFZoomChromeStrings(
                zoomControls: String(localized: "filePreview.pdf.zoomControls", defaultValue: "Zoom Controls"),
                zoomOut: String(localized: "filePreview.pdf.zoomOut", defaultValue: "Zoom Out"),
                actualSize: String(localized: "filePreview.pdf.actualSize", defaultValue: "Actual Size"),
                zoomIn: String(localized: "filePreview.pdf.zoomIn", defaultValue: "Zoom In"),
                zoomToFit: String(localized: "filePreview.pdf.zoomToFit", defaultValue: "Zoom to Fit"),
                rotateLeft: String(localized: "filePreview.pdf.rotateLeft", defaultValue: "Rotate Left"),
                rotateRight: String(localized: "filePreview.pdf.rotateRight", defaultValue: "Rotate Right")
            ),
            fileOpenMenu: currentURL.flatMap { host?.makeFileOpenChromeMenu(for: $0) },
            zoomOut: { [weak self] in self?.zoomOut() },
            actualSize: { [weak self] in self?.actualSize() },
            zoomIn: { [weak self] in self?.zoomIn() },
            zoomToFit: { [weak self] in self?.zoomToFit() },
            rotateLeft: { [weak self] in self?.rotateLeft() },
            rotateRight: { [weak self] in self?.rotateRight() }
        ))
    }

    @objc private func zoomOut() {
        pdfView.autoScales = false
        setPDFScaleFactor(pdfView.scaleFactor / FilePreviewZoomInteraction.standard.step, preservingVisibleCenter: true)
    }

    @objc private func zoomIn() {
        pdfView.autoScales = false
        setPDFScaleFactor(pdfView.scaleFactor * FilePreviewZoomInteraction.standard.step, preservingVisibleCenter: true)
    }

    @objc private func zoomToFit() {
        pdfView.autoScales = true
        refreshPDFSmartFitPreservingVisibleCenter()
    }

    @objc private func actualSize() {
        pdfView.autoScales = false
        setPDFScaleFactor(1.0, preservingVisibleCenter: true)
    }

    @objc private func rotateLeft() {
        rotateCurrentPDFPage(by: -90)
    }

    @objc private func rotateRight() {
        rotateCurrentPDFPage(by: 90)
    }

    @objc private func toggleSidebar() {
        isSidebarVisible.toggle()
        updateSidebarVisibility()
        updateChromeRootViews()
    }

    @objc private func selectThumbnailSidebar() {
        sidebarMode = .thumbnails
        isSidebarVisible = true
        didUserResizeSidebar = false
        lastSidebarWidth = preferredSidebarWidthForCurrentMode()
        logSidebarWidth(reason: "selectThumbnails", proposed: lastSidebarWidth)
        updateSidebarVisibility()
        updateSidebarContent()
        updateChromeRootViews()
    }

    @objc private func selectTableOfContentsSidebar() {
        sidebarMode = .tableOfContents
        isSidebarVisible = true
        didUserResizeSidebar = false
        lastSidebarWidth = preferredSidebarWidthForCurrentMode()
        logSidebarWidth(reason: "selectTableOfContents", proposed: lastSidebarWidth)
        updateSidebarVisibility()
        updateSidebarContent()
        updateChromeRootViews()
    }

    @objc private func selectContinuousScroll() {
        displayMode = .continuousScroll
        applyDisplayMode()
        updateChromeRootViews()
    }

    @objc private func selectSinglePage() {
        displayMode = .singlePage
        applyDisplayMode()
        updateChromeRootViews()
    }

    @objc private func selectTwoPages() {
        displayMode = .twoPages
        applyDisplayMode()
        updateChromeRootViews()
    }

    @objc private func pdfPageChanged() {
        logPDFResizeProbe(
            "pageChanged suppressed=\(suppressPDFPageChangeNotifications ? 1 : 0) \(pdfDebugState())"
        )
        guard !suppressPDFPageChangeNotifications else { return }
        updatePageControls()
    }

    @objc private func pdfChromeStyleChanged() {
        let variant = FilePreviewPDFChromeStyleVariant.current()
        guard variant != chromeStyleVariant else { return }
        chromeStyleVariant = variant
        updateChromeRootViews()
    }

    @objc private func pdfClipBoundsChanged(_ notification: Notification) {
        guard let clipView = notification.object as? NSClipView,
              clipView === observedPDFClipView,
              pdfView.document != nil,
              !suppressPDFPageChangeNotifications else { return }
        updatePageControls()
    }

    private func updatePageControls(
        pageIndexOverride: Int? = nil,
        scrollThumbnailToVisible: Bool = true
    ) {
        guard let document = pdfView.document, document.pageCount > 0 else {
            pageLabel.stringValue = ""
            logPDFResizeProbe("updatePageControls emptyDoc scrollThumb=\(scrollThumbnailToVisible ? 1 : 0)")
            return
        }

        let pageIndex: Int
        if let pageIndexOverride,
           pageIndexOverride >= 0,
           pageIndexOverride < document.pageCount {
            pageIndex = pageIndexOverride
        } else if let visiblePageIndex = visiblePDFPageIndex(for: document) {
            pageIndex = visiblePageIndex
        } else {
            pageIndex = 0
        }
        let format = String(localized: "filePreview.pdf.pageCount", defaultValue: "Page %d of %d")
        pageLabel.stringValue = String.localizedStringWithFormat(format, pageIndex + 1, document.pageCount)
        thumbnailView.selectPage(at: pageIndex, scrollToVisible: scrollThumbnailToVisible)
        let explicit = pageIndexOverride == nil ? 0 : 1
        logPDFResizeProbe(
            "updatePageControls page=\(pageIndex + 1)/\(document.pageCount) " +
            "explicit=\(explicit) scrollThumb=\(scrollThumbnailToVisible ? 1 : 0) \(pdfDebugState())"
        )
    }

    private func visiblePDFPageIndex(for document: PDFDocument) -> Int? {
        let page = displayMode == .continuousScroll
            ? selectedVisiblePDFPage()
            : pdfView.currentPage
        guard let page else { return nil }
        let pageIndex = document.index(for: page)
        guard pageIndex >= 0 else { return nil }
        return pageIndex
    }

    private func selectedVisiblePDFPage() -> PDFPage? {
        FilePreviewPDFVisiblePageResolver.selectedVisiblePage(in: pdfView, scrollView: pdfScrollView())
    }

    private func topVisiblePDFPage() -> PDFPage? {
        FilePreviewPDFVisiblePageResolver.topVisiblePage(in: pdfView, scrollView: pdfScrollView())
    }

    private func updateSidebarVisibility() {
        if isSidebarVisible {
            sidebarHost.isHidden = false
            let targetWidth = didUserResizeSidebar
                ? lastSidebarWidth
                : preferredSidebarWidthForCurrentMode()
            applySidebarWidth(targetWidth)
        } else {
            let currentSidebarWidth = sidebarHost.frame.width
            if currentSidebarWidth >= minimumSidebarWidthForCurrentMode() {
                lastSidebarWidth = currentSidebarWidth
            }
            applyPDFViewportChange {
                self.sidebarHost.isHidden = true
                self.splitView.adjustSubviews()
                self.splitView.layoutSubtreeIfNeeded()
                self.layoutFloatingChrome()
            }
        }
        layoutFloatingChrome()
    }

    private func clampedSidebarWidth(_ proposedWidth: CGFloat) -> CGFloat {
        FilePreviewPDFSizing.clampedSidebarWidth(
            proposedWidth,
            containerWidth: max(splitView.bounds.width, bounds.width),
            dividerThickness: splitView.dividerThickness,
            minimumWidth: minimumSidebarWidthForCurrentMode()
        )
    }

    private func minimumSidebarWidthForCurrentMode() -> CGFloat {
        switch sidebarMode {
        case .thumbnails:
            FilePreviewPDFSizing.minimumThumbnailSidebarWidth
        case .tableOfContents:
            Metrics.minimumSidebarWidth
        }
    }

    private func preferredSidebarWidthForCurrentMode() -> CGFloat {
        switch sidebarMode {
        case .thumbnails:
            thumbnailView.preferredSidebarWidth()
        case .tableOfContents:
            FilePreviewPDFSizing.preferredOutlineSidebarWidth(for: outlineRoot)
        }
    }

    private func logSidebarWidth(
        reason: String,
        proposed: CGFloat? = nil,
        applied: CGFloat? = nil
    ) {
        #if DEBUG
        let mode = sidebarMode == .tableOfContents ? "toc" : "thumbnails"
        let currentWidth = sidebarHost.frame.width
        let preferredWidth = preferredSidebarWidthForCurrentMode()
        let thumbnailWidth = thumbnailView.preferredSidebarWidth()
        let tocWidth = FilePreviewPDFSizing.preferredOutlineSidebarWidth(for: outlineRoot)
        CMUXDebugLog.logDebugEvent(
            "filePreview.pdf.sidebarWidth reason=\(reason) mode=\(mode) " +
            "current=\(formatSidebarWidth(currentWidth)) " +
            "proposed=\(formatSidebarWidth(proposed)) " +
            "applied=\(formatSidebarWidth(applied)) " +
            "preferred=\(formatSidebarWidth(preferredWidth)) " +
            "thumbnailPreferred=\(formatSidebarWidth(thumbnailWidth)) " +
            "tocPreferred=\(formatSidebarWidth(tocWidth)) " +
            "min=\(formatSidebarWidth(minimumSidebarWidthForCurrentMode())) " +
            "content=\(formatSidebarWidth(contentHost.frame.width))"
        )
        #endif
    }

    #if DEBUG
    private func formatSidebarWidth(_ width: CGFloat?) -> String {
        guard let width, width.isFinite else { return "nil" }
        return String(format: "%.1f", Double(width))
    }
    #endif

    private func applyPreferredSidebarWidthIfNeeded() {
        guard !didUserResizeSidebar,
              didSetInitialSidebarWidth,
              isSidebarVisible,
              !sidebarHost.isHidden else { return }
        let preferredWidth = preferredSidebarWidthForCurrentMode()
        guard abs(sidebarHost.frame.width - preferredWidth) > 0.5 else { return }
        logSidebarWidth(reason: "applyPreferred", proposed: preferredWidth)
        applySidebarWidth(preferredWidth)
    }

    private func applySidebarWidth(_ proposedWidth: CGFloat) {
        let width = clampedSidebarWidth(proposedWidth)
        lastSidebarWidth = width
        logSidebarWidth(reason: "applySidebarWidth", proposed: proposedWidth, applied: width)
        let applyWidth = {
            self.isApplyingSidebarWidth = true
            defer { self.isApplyingSidebarWidth = false }
            self.splitView.setPosition(width, ofDividerAt: 0)
            self.splitView.adjustSubviews()
            self.splitView.layoutSubtreeIfNeeded()
            self.layoutFloatingChrome()
        }

        applyPDFViewportChange(applyWidth)
    }

    private func applyPDFViewportChange(_ change: () -> Void) {
        guard pdfView.document != nil else {
            change()
            return
        }
        preserveVisiblePDFTop {
            change()
            refreshPDFSmartFitWithoutViewportRestore()
        }
    }

    public func splitViewWillResizeSubviews(_ notification: Notification) {
        guard !isApplyingSidebarWidth,
              isSidebarVisible,
              !sidebarHost.isHidden,
              pdfView.document != nil else { return }
        pdfResizeSequence += 1
        activePDFResizeID = pdfResizeSequence
        preparePDFViewportSnapshot()
        pendingSidebarResizeSnapshot = FilePreviewPDFViewportSnapshot.capture(
            in: pdfView,
            scrollView: pdfScrollView(),
            anchor: .top
        )
        logPDFResizeProbe(
            "will id=\(activePDFResizeID ?? -1) event=\(debugEventType()) " +
            "snapshot=\(debugSnapshot(pendingSidebarResizeSnapshot)) \(pdfDebugState())"
        )
    }

    public func splitViewDidResizeSubviews(_ notification: Notification) {
        guard isSidebarVisible, !sidebarHost.isHidden else { return }
        let sidebarWidth = sidebarHost.frame.width
        guard sidebarWidth >= minimumSidebarWidthForCurrentMode() else { return }
        logSidebarWidth(reason: "splitViewDidResize", applied: sidebarWidth)
        guard !isApplyingSidebarWidth else { return }
        let resizeID: Int
        if let activePDFResizeID {
            resizeID = activePDFResizeID
        } else {
            pdfResizeSequence += 1
            resizeID = pdfResizeSequence
            self.activePDFResizeID = resizeID
        }
        logPDFResizeProbe(
            "did.begin id=\(resizeID) event=\(debugEventType()) " +
            "snapshot=\(debugSnapshot(pendingSidebarResizeSnapshot)) \(pdfDebugState())"
        )
        if NSApp.currentEvent?.type == .leftMouseDragged {
            didUserResizeSidebar = true
        }
        lastSidebarWidth = sidebarWidth
        layoutFloatingChrome()
        let resizeSnapshot = pendingSidebarResizeSnapshot
        pendingSidebarResizeSnapshot = nil
        withSuppressedPDFPageChangeNotifications {
            if let resizeSnapshot {
                refreshPDFSmartFitWithoutViewportRestore()
                resizeSnapshot.restore(in: pdfView, scrollView: pdfScrollView())
            } else {
                refreshPDFSmartFitPreservingVisibleTop()
            }
        }
        logPDFResizeProbe("did.end id=\(resizeID) \(pdfDebugState())")
        activePDFResizeID = nil
    }

    public func splitView(
        _ splitView: NSSplitView,
        constrainMinCoordinate proposedMinimumPosition: CGFloat,
        ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        minimumSidebarWidthForCurrentMode()
    }

    public func splitView(
        _ splitView: NSSplitView,
        constrainMaxCoordinate proposedMaximumPosition: CGFloat,
        ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        clampedSidebarWidth(Metrics.maximumSidebarWidth)
    }

    private func updateSidebarContent() {
        let showingThumbnails = sidebarMode == .thumbnails
        let showingTableOfContents = sidebarMode == .tableOfContents
        let hasOutline = (outlineRoot?.numberOfChildren ?? 0) > 0
        thumbnailView.isHidden = !showingThumbnails
        outlineScrollView.isHidden = !showingTableOfContents || !hasOutline
        outlinePlaceholder.isHidden = !showingTableOfContents || hasOutline
    }

    private func applyDisplayMode() {
        switch displayMode {
        case .continuousScroll:
            pdfView.displayMode = .singlePageContinuous
            pdfView.displayDirection = .vertical
        case .singlePage:
            pdfView.displayMode = .singlePage
            pdfView.displayDirection = .vertical
        case .twoPages:
            pdfView.displayMode = .twoUp
            pdfView.displayDirection = .horizontal
        }
        pdfView.autoScales = true
        updatePDFScrollObserver()
        refreshPDFSmartFitPreservingVisibleTop()
    }

    private func refreshPDFSmartFitWithoutViewportRestore() {
        guard pdfView.document != nil, pdfView.autoScales else { return }
        logPDFResizeProbe("smartFit.begin \(pdfDebugState())")
        contentHost.layoutSubtreeIfNeeded()
        pdfView.layoutSubtreeIfNeeded()
        pdfView.autoScales = false
        pdfView.autoScales = true
        pdfView.layoutDocumentView()
        updatePDFScrollObserver()
        logPDFResizeProbe("smartFit.end \(pdfDebugState())")
    }

    private func refreshPDFSmartFitPreservingVisibleTop() {
        preserveVisiblePDFTop {
            refreshPDFSmartFitWithoutViewportRestore()
        }
    }

    private func refreshPDFSmartFitPreservingVisibleCenter() {
        preserveVisiblePDFCenter {
            refreshPDFSmartFitWithoutViewportRestore()
        }
    }

    private func zoomPDF(with event: NSEvent, factor: CGFloat) {
        guard pdfView.document != nil else { return }
        guard factor.isFinite, factor > 0 else { return }
        pdfView.autoScales = false
        setPDFScaleFactor(pdfView.scaleFactor * factor, preservingVisibleCenter: true)
    }

    private func togglePDFSmartZoom() {
        if pdfView.autoScales {
            actualSize()
        } else {
            zoomToFit()
        }
    }

    private func rotatePDF(with event: NSEvent) {
        rotationAccumulator += CGFloat(event.rotation)
        if rotationAccumulator >= 45 {
            rotateCurrentPDFPage(by: -90)
            rotationAccumulator = 0
        } else if rotationAccumulator <= -45 {
            rotateCurrentPDFPage(by: 90)
            rotationAccumulator = 0
        }
    }

    private func swipePDF(with event: NSEvent) {
        if event.deltaX < 0 {
            navigatePDFPage(by: 1)
        } else if event.deltaX > 0 {
            navigatePDFPage(by: -1)
        }
    }

    private func navigatePDFPage(by delta: Int) {
        guard delta != 0,
              let document = pdfView.document,
              document.pageCount > 0 else { return }
        let currentPageIndex = visiblePDFPageIndex(for: document) ?? 0
        let nextPageIndex = min(max(currentPageIndex + delta, 0), document.pageCount - 1)
        guard nextPageIndex != currentPageIndex,
              let page = document.page(at: nextPageIndex) else { return }
        goToPDFPage(page)
    }

    private func goToPDFPage(_ page: PDFPage, scrollThumbnailToVisible: Bool = true) {
        guard let document = pdfView.document else { return }
        let pageIndex = document.index(for: page)
        guard pageIndex >= 0, pageIndex < document.pageCount else { return }
        withSuppressedPDFPageChangeNotifications {
            pdfView.go(to: page)
        }
        updatePageControls(
            pageIndexOverride: pageIndex,
            scrollThumbnailToVisible: scrollThumbnailToVisible
        )
    }

    private func rotateCurrentPDFPage(by degrees: Int) {
        guard let page = pdfView.currentPage else { return }
        page.rotation = normalizedRotation(page.rotation + degrees)
        pdfView.layoutDocumentView()
        pdfView.setNeedsDisplay(pdfView.bounds)
        if let document = pdfView.document {
            thumbnailView.reloadPage(at: document.index(for: page))
        }
    }

    private func setPDFScaleFactor(_ nextScale: CGFloat, preservingVisibleCenter: Bool = false) {
        let clamped = min(max(nextScale, pdfView.minScaleFactor), pdfView.maxScaleFactor)
        guard clamped.isFinite else { return }
        if preservingVisibleCenter {
            preserveVisiblePDFCenter {
                pdfView.scaleFactor = clamped
            }
        } else {
            pdfView.scaleFactor = clamped
        }
    }

    private func preparePDFViewportSnapshot() {
        contentHost.layoutSubtreeIfNeeded()
        pdfView.layoutSubtreeIfNeeded()
    }

    private func preserveVisiblePDFTop(_ viewportChange: () -> Void) {
        preservePDFViewport(anchor: .top, viewportChange)
    }

    private func preserveVisiblePDFCenter(_ viewportChange: () -> Void) {
        preservePDFViewport(anchor: .center, viewportChange)
    }

    private func preservePDFViewport(
        anchor: FilePreviewPDFViewportAnchor,
        _ viewportChange: () -> Void
    ) {
        preparePDFViewportSnapshot()
        guard let snapshot = FilePreviewPDFViewportSnapshot.capture(
            in: pdfView,
            scrollView: pdfScrollView(),
            anchor: anchor
        ) else {
            logPDFResizeProbe("preserve.noSnapshot anchor=\(debugAnchor(anchor)) \(pdfDebugState())")
            viewportChange()
            return
        }
        logPDFResizeProbe(
            "preserve.begin anchor=\(debugAnchor(anchor)) snapshot=\(debugSnapshot(snapshot)) \(pdfDebugState())"
        )
        withSuppressedPDFPageChangeNotifications {
            viewportChange()
            snapshot.restore(in: pdfView, scrollView: pdfScrollView())
        }
        logPDFResizeProbe("preserve.end anchor=\(debugAnchor(anchor)) \(pdfDebugState())")
    }

    private func withSuppressedPDFPageChangeNotifications(_ body: () -> Void) {
        let previousValue = suppressPDFPageChangeNotifications
        suppressPDFPageChangeNotifications = true
        defer { suppressPDFPageChangeNotifications = previousValue }
        body()
    }

    private func registerFocusEndpoint() {
        host?.attachPreviewFocus(root: pdfView, primaryResponder: pdfView, intent: .pdfCanvas)
        host?.attachPreviewFocus(
            root: thumbnailView,
            primaryResponder: thumbnailView.focusResponder(),
            intent: .pdfThumbnails
        )
        host?.attachPreviewFocus(root: outlineView, primaryResponder: outlineView, intent: .pdfOutline)
    }

    private func setActivePDFRegion(_ region: FilePreviewPanelFocusIntent?) {
        guard activePDFRegion != region else { return }
        activePDFRegion = region
        thumbnailView.setSelectionActive(region == .pdfThumbnails)
        guard let region else { return }
        host?.noteFilePreviewFocusIntent(region)
        host?.syncKeyboardFocusAfterFirstResponderChange(in: window)
    }

    private func updatePDFThumbnailSelectionFocus() {
        setActivePDFRegion(currentPDFFocusRegion())
    }

    private func updatePDFScrollObserver() {
        guard let clipView = pdfScrollView()?.contentView else { return }
        guard observedPDFClipView !== clipView else { return }
        removePDFScrollObserver()
        observedPDFClipView = clipView
        clipView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(pdfClipBoundsChanged(_:)),
            name: NSView.boundsDidChangeNotification,
            object: clipView
        )
    }

    private func removePDFScrollObserver() {
        if let observedPDFClipView {
            NotificationCenter.default.removeObserver(
                self,
                name: NSView.boundsDidChangeNotification,
                object: observedPDFClipView
            )
        }
        observedPDFClipView = nil
    }

    private func currentPDFFocusRegion() -> FilePreviewPanelFocusIntent? {
        guard window?.isKeyWindow == true,
              !isHiddenOrHasHiddenAncestor,
              let intent = host?.currentFilePreviewFocusIntent(in: window) else { return nil }
        switch intent {
        case .pdfCanvas, .pdfThumbnails, .pdfOutline:
            return intent
        case .textEditor, .imageCanvas, .mediaPlayer, .quickLook:
            return nil
        }
    }

    #if DEBUG
    private func logPDFResizeProbe(_ message: @autoclosure () -> String) {
        CMUXDebugLog.logDebugEvent("filePreview.pdf.resize \(message())")
    }

    private func pdfDebugState() -> String {
        let document = pdfView.document
        let pageDescription: String
        if let document, let currentPage = pdfView.currentPage {
            let pageIndex = document.index(for: currentPage)
            pageDescription = pageIndex >= 0 ? "\(pageIndex + 1)/\(document.pageCount)" : "unknown/\(document.pageCount)"
        } else if let document {
            pageDescription = "nil/\(document.pageCount)"
        } else {
            pageDescription = "nil"
        }
        let topPageDescription: String
        if let document, let topPage = topVisiblePDFPage() {
            let pageIndex = document.index(for: topPage)
            topPageDescription = pageIndex >= 0 ? "\(pageIndex + 1)/\(document.pageCount)" : "unknown/\(document.pageCount)"
        } else {
            topPageDescription = "nil"
        }
        let scrollView = pdfScrollView()
        let clipBounds = scrollView?.contentView.bounds
        let documentBounds = scrollView?.documentView?.bounds
        return "mode=\(sidebarMode == .tableOfContents ? "toc" : "thumbs") " +
            "visible=\(isSidebarVisible ? 1 : 0) " +
            "sidebar=\(debugNumber(sidebarHost.frame.width)) " +
            "content=\(debugNumber(contentHost.frame.width)) " +
            "auto=\(pdfView.autoScales ? 1 : 0) " +
            "scale=\(debugNumber(pdfView.scaleFactor)) " +
            "page=\(pageDescription) " +
            "topPage=\(topPageDescription) " +
            "clip=\(debugRect(clipBounds)) " +
            "doc=\(debugRect(documentBounds))"
    }

    private func debugSnapshot(_ snapshot: FilePreviewPDFViewportSnapshot?) -> String {
        snapshot?.debugSummary(document: pdfView.document) ?? "nil"
    }

    private func debugAnchor(_ anchor: FilePreviewPDFViewportAnchor) -> String {
        switch anchor {
        case .center:
            "center"
        case .top:
            "top"
        }
    }

    private func debugEventType() -> String {
        guard let event = NSApp.currentEvent else { return "nil" }
        return "\(event.type.rawValue)"
    }

    private func debugRect(_ rect: CGRect?) -> String {
        guard let rect else { return "nil" }
        return "(\(debugNumber(rect.origin.x)),\(debugNumber(rect.origin.y)) " +
            "\(debugNumber(rect.width))x\(debugNumber(rect.height)))"
    }

    private func debugNumber(_ value: CGFloat) -> String {
        guard value.isFinite else { return "nan" }
        return String(format: "%.1f", Double(value))
    }
    #else
    private func logPDFResizeProbe(_ message: @autoclosure () -> String) {}

    private func pdfDebugState() -> String { "" }

    private func debugSnapshot(_ snapshot: FilePreviewPDFViewportSnapshot?) -> String { "" }

    private func debugAnchor(_ anchor: FilePreviewPDFViewportAnchor) -> String { "" }

    private func debugEventType() -> String { "" }
    #endif

    private func pdfScrollView() -> NSScrollView? {
        firstScrollView(in: pdfView)
    }

    private func firstScrollView(in view: NSView) -> NSScrollView? {
        if let scrollView = view as? NSScrollView {
            return scrollView
        }
        for subview in view.subviews {
            if let scrollView = firstScrollView(in: subview) {
                return scrollView
            }
        }
        return nil
    }

    private func normalizedRotation(_ degrees: Int) -> Int {
        ((degrees % 360) + 360) % 360
    }

    public func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        let outline = item as? PDFOutline ?? outlineRoot
        return outline?.numberOfChildren ?? 0
    }

    public func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let outline = item as? PDFOutline else { return false }
        return outline.numberOfChildren > 0
    }

    public func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        let outline = item as? PDFOutline ?? outlineRoot
        return outline?.child(at: index) ?? NSNull()
    }

    public func outlineView(
        _ outlineView: NSOutlineView,
        viewFor tableColumn: NSTableColumn?,
        item: Any
    ) -> NSView? {
        guard let outline = item as? PDFOutline else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("filePreviewPDFOutlineCell")
        let cell = outlineView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView
            ?? makeOutlineCell(identifier: identifier)
        cell.textField?.stringValue = outline.label ?? ""
        return cell
    }

    public func outlineViewSelectionDidChange(_ notification: Notification) {
        setActivePDFRegion(.pdfOutline)
        let selectedRow = outlineView.selectedRow
        guard selectedRow >= 0,
              let outline = outlineView.item(atRow: selectedRow) as? PDFOutline,
              let destination = outline.destination,
              let page = destination.page else { return }
        goToPDFPage(page)
    }

    private func makeOutlineCell(identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = identifier
        let textField = NSTextField(labelWithString: "")
        textField.lineBreakMode = .byTruncatingMiddle
        textField.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(textField)
        cell.textField = textField
        NSLayoutConstraint.activate([
            textField.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
            textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }
}
