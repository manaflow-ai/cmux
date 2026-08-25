import AppKit
import CmuxFoundation
import CmuxSettings
import SwiftUI

@MainActor
protocol FilePreviewTextEditingPanel: AnyObject {
    var textContent: String { get }

    func attachTextView(_ textView: NSTextView)
    func retryPendingFocus()
    func updateTextContent(_ nextContent: String)
    @discardableResult
    func saveTextContent() -> Task<Void, Never>?
}

struct FilePreviewTextEditor<PanelModel>: NSViewRepresentable where PanelModel: ObservableObject & FilePreviewTextEditingPanel {
    @ObservedObject var panel: PanelModel
    let isVisibleInUI: Bool
    let themeBackgroundColor: NSColor
    let themeForegroundColor: NSColor
    let drawsBackground: Bool
    /// Persisted editor settings are observed only while this text editor is mounted.
    /// Keeping them here prevents Settings changes from invalidating unrelated preview
    /// surfaces, especially the Markdown WebView while a font-family field is edited.
    @AppStorage(FilePreviewWordWrapSettings.key) private var fileEditorWordWrap = FilePreviewWordWrapSettings.defaultEnabled
    @AppStorage(FilePreviewFontSizeSettings.key) private var fileEditorFontSize = FilePreviewFontSizeSettings.defaultPointSize
    @AppStorage(FilePreviewFontFamilySettings.key) private var fileEditorFontFamily = FilePreviewFontFamilySettings.defaultFamily
    @AppStorage(FilePreviewLineHeightSettings.key) private var fileEditorLineHeight = FilePreviewLineHeightSettings.defaultMultiplier

    func makeCoordinator() -> Coordinator {
        Coordinator(panel: panel)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.isHidden = !isVisibleInUI
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = drawsBackground

        let textView = SavingTextView.makeFilePreviewTextView(
            fontFamily: fileEditorFontFamily,
            fontSize: CGFloat(fileEditorFontSize),
            lineHeight: CGFloat(fileEditorLineHeight)
        )
        textView.panel = panel
        textView.delegate = context.coordinator
        textView.drawsBackground = drawsBackground
        textView.string = panel.textContent
        textView.applyCurrentPreviewFont()
        textView.configurePreviewTypography(
            fontFamily: fileEditorFontFamily,
            defaultFontSize: CGFloat(fileEditorFontSize),
            lineHeight: CGFloat(fileEditorLineHeight)
        )
        textView.applyCurrentPreviewLineHeight()
        panel.attachTextView(textView)

        scrollView.documentView = textView
        textView.applyFilePreviewWordWrap(fileEditorWordWrap, scrollView: scrollView)
        Self.applyTheme(
            to: scrollView,
            backgroundColor: themeBackgroundColor,
            foregroundColor: themeForegroundColor,
            drawsBackground: drawsBackground
        )
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.panel = panel
        scrollView.isHidden = !isVisibleInUI
        Self.applyTheme(
            to: scrollView,
            backgroundColor: themeBackgroundColor,
            foregroundColor: themeForegroundColor,
            drawsBackground: drawsBackground
        )
        guard let textView = scrollView.documentView as? SavingTextView else { return }
        textView.panel = panel
        textView.applyFilePreviewTextEditorInsets()
        textView.applyFilePreviewWordWrap(fileEditorWordWrap, scrollView: scrollView)
        panel.attachTextView(textView)

        let contentNeedsUpdate = textView.string != panel.textContent
        let selectedRanges = contentNeedsUpdate ? textView.selectedRanges : []
        let visibleOrigin = scrollView.contentView.bounds.origin
        context.coordinator.withPanelUpdate {
            // Reconcile external content before formatting the text storage. Both
            // operations can emit NSText.didChangeNotification, so they must share
            // the same delegate guard or a reload can publish stale editor text.
            if contentNeedsUpdate {
                textView.string = panel.textContent
            }
            textView.configurePreviewTypography(
                fontFamily: fileEditorFontFamily,
                defaultFontSize: CGFloat(fileEditorFontSize),
                lineHeight: CGFloat(fileEditorLineHeight)
            )
            if contentNeedsUpdate {
                // Reapply attributes after replacing the string; NSTextView can
                // reset typing/storage attributes when its content is replaced.
                textView.applyCurrentPreviewFont()
                textView.applyCurrentPreviewLineHeight()
            }
        }
        guard contentNeedsUpdate else { return }
        let contentLength = (textView.string as NSString).length
        let clampedRanges = selectedRanges.map { value -> NSValue in
            let range = value.rangeValue
            let location = min(range.location, contentLength)
            let length = min(range.length, contentLength - location)
            return NSValue(range: NSRange(location: location, length: length))
        }
        textView.setSelectedRanges(clampedRanges, affinity: .downstream, stillSelecting: false)
        scrollView.layoutSubtreeIfNeeded()
        let clipView = scrollView.contentView
        let constrained = clipView.constrainBoundsRect(
            NSRect(origin: visibleOrigin, size: clipView.bounds.size)
        )
        clipView.scroll(to: constrained.origin)
        scrollView.reflectScrolledClipView(clipView)
    }

    static func applyTheme(
        to scrollView: NSScrollView,
        backgroundColor: NSColor,
        foregroundColor: NSColor,
        drawsBackground: Bool
    ) {
        let resolvedBackgroundColor = drawsBackground ? backgroundColor : .clear
        scrollView.drawsBackground = drawsBackground
        scrollView.backgroundColor = resolvedBackgroundColor
        scrollView.contentView.drawsBackground = drawsBackground
        scrollView.contentView.backgroundColor = resolvedBackgroundColor
        if let textView = scrollView.documentView as? NSTextView {
            textView.drawsBackground = drawsBackground
            textView.backgroundColor = resolvedBackgroundColor
            textView.textColor = foregroundColor
            textView.insertionPointColor = foregroundColor
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var panel: PanelModel
        var isApplyingPanelUpdate = false

        init(panel: PanelModel) {
            self.panel = panel
        }

        /// Runs a representable-driven text update while suppressing delegate
        /// callbacks caused by content or attribute synchronization.
        @discardableResult
        func withPanelUpdate<Result>(_ body: () -> Result) -> Result {
            let previousValue = isApplyingPanelUpdate
            isApplyingPanelUpdate = true
            defer { isApplyingPanelUpdate = previousValue }
            return body()
        }

        deinit {}

        func textDidChange(_ notification: Notification) {
            guard !isApplyingPanelUpdate,
                  let textView = notification.object as? NSTextView else { return }
            panel.updateTextContent(textView.string)
        }
    }
}

extension SavingTextView {
    /// Builds the File Preview text view configured for large plain-text files.
    ///
    /// File Preview opens files up to `FilePreviewPanel.maximumLoadedTextBytes` (16 MB), which can
    /// be hundreds of thousands of lines. Selection responsiveness on that content is the reason
    /// this configuration is centralized; see `manaflow-ai/cmux#4576`.
    static func makeFilePreviewTextView(
        fontFamily: String = FilePreviewFontFamilySettings.defaultFamily,
        fontSize: CGFloat = CGFloat(FilePreviewFontSizeSettings.defaultPointSize),
        lineHeight: CGFloat = CGFloat(FilePreviewLineHeightSettings.defaultMultiplier)
    ) -> SavingTextView {
        // Build an EXPLICIT TextKit 1 stack so this view is never TextKit 2.
        //
        // A default `NSTextView()` is TextKit 2: selection/hit-testing then runs through
        // `NSTextSelectionNavigation`, whose work is O(N) in line-fragment count, so clicking or
        // drag-selecting in a large document pegs the main thread inside AppKit's modal
        // mouse-tracking loop and freezes the whole app (`manaflow-ai/cmux#4576`, `#5255`).
        //
        // Merely *reading* `.layoutManager` afterward — the previous mitigation — only drops the
        // view to TextKit 2 *compatibility* mode: `textLayoutManager` stays non-nil and the slow
        // selection path remains active (confirmed by live `sample` captures of the hung process).
        // Constructing the view from an `NSTextStorage` / `NSLayoutManager` / `NSTextContainer`
        // stack is the only way to guarantee `textLayoutManager == nil`, i.e. a pure TextKit 1 view
        // whose hit-testing uses `NSLayoutManager` (O(log N) with non-contiguous layout).
        let textStorage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        // Lazy glyph layout so multi-hundred-thousand-line documents still open instantly.
        layoutManager.allowsNonContiguousLayout = true
        textStorage.addLayoutManager(layoutManager)
        let textContainer = NSTextContainer(
            size: NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        )
        // No-wrap baseline; `applyFilePreviewWordWrap(_:scrollView:)` flips this live per the
        // `fileEditor.wordWrap` setting.
        textContainer.widthTracksTextView = false
        layoutManager.addTextContainer(textContainer)

        let textView = SavingTextView(frame: .zero, textContainer: textContainer)
        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.usesFindPanel = true
        textView.usesFontPanel = false
        textView.configurePreviewTypography(
            fontFamily: fontFamily,
            defaultFontSize: fontSize,
            lineHeight: lineHeight
        )
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true
        textView.autoresizingMask = [.width]
        textView.applyFilePreviewTextEditorInsets()
        return textView
    }
}

extension NSTextView {
    /// Configures the text view and its scroll view for soft line wrapping
    /// (`wrap == true`) or the no-wrap baseline with a horizontal scroller
    /// (`wrap == false`). Idempotent, so it is safe to call on every SwiftUI
    /// update; toggling the `fileEditor.wordWrap` setting reflows open editors.
    func applyFilePreviewWordWrap(_ wrap: Bool, scrollView: NSScrollView) {
        guard let textContainer else { return }
        scrollView.hasHorizontalScroller = !wrap
        isHorizontallyResizable = !wrap
        if wrap {
            textContainer.widthTracksTextView = true
            // `widthTracksTextView` keeps the container pinned to the text view
            // width, so wrapping is correct even before the scroll view is laid
            // out. Only snap the frame/container to a real measured width to
            // avoid collapsing to a zero-width container during `makeNSView`,
            // before the clip view has a size; `updateNSView` re-runs once laid
            // out and reflows.
            let visibleWidth = scrollView.contentSize.width
            if visibleWidth > 0 {
                textContainer.size = NSSize(width: visibleWidth, height: .greatestFiniteMagnitude)
                setFrameSize(NSSize(width: visibleWidth, height: frame.height))
            }
        } else {
            textContainer.widthTracksTextView = false
            textContainer.size = NSSize(
                width: CGFloat.greatestFiniteMagnitude,
                height: CGFloat.greatestFiniteMagnitude
            )
        }
    }

    func applyFilePreviewTextEditorInsets() {
        let targetInset = SavingTextView.filePreviewTextContainerInset
        if textContainerInset.width != targetInset.width || textContainerInset.height != targetInset.height {
            textContainerInset = targetInset
        }
        if textContainer?.lineFragmentPadding != SavingTextView.filePreviewLineFragmentPadding {
            textContainer?.lineFragmentPadding = SavingTextView.filePreviewLineFragmentPadding
        }
    }
}

final class SavingTextView: NSTextView {
    /// Insets around the editor's TextKit text container.
    fileprivate static let filePreviewTextContainerInset = NSSize(width: 12, height: 10)
    /// Extra padding inserted at the start of each line fragment.
    fileprivate static let filePreviewLineFragmentPadding: CGFloat = 0

    private static let previewFontZoomShortcutActions: [KeyboardShortcutSettings.Action] = [
        .browserZoomIn,
        .browserZoomOut,
        .browserZoomReset,
    ]

    weak var panel: (any FilePreviewTextEditingPanel)?
    /// Configured baseline size used by the live zoom and reset actions.
    var configuredPreviewFontSize = CGFloat(FilePreviewFontSizeSettings.defaultPointSize)
    /// Current per-editor size after live zoom adjustments.
    var previewFontSize = CGFloat(FilePreviewFontSizeSettings.defaultPointSize)
    /// Normalized configured family used for the current font.
    var previewFontFamily = FilePreviewFontFamilySettings.defaultFamily
    /// Current paragraph line-height multiplier.
    var previewLineHeight = CGFloat(FilePreviewLineHeightSettings.defaultMultiplier)
    /// Whether the representable has supplied its first typography snapshot.
    var hasConfiguredPreviewTypography = false
    private var pendingEditorShortcutChordPrefix: ShortcutStroke?
    private var fontMagnificationObserver: GlobalFontMagnificationChangeObserver?

    convenience init() {
        self.init(frame: .zero, textContainer: nil)
    }

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
        installFontMagnificationObserver()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        installFontMagnificationObserver()
    }

    deinit {}

    private func installFontMagnificationObserver() {
        fontMagnificationObserver = GlobalFontMagnificationChangeObserver { [weak self] in
            self?.applyCurrentPreviewFont()
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        clearPendingShortcutChordPrefixes()
        applyFilePreviewTextEditorInsets()
        panel?.retryPendingFocus()
    }

    override func resignFirstResponder() -> Bool {
        let didResign = super.resignFirstResponder()
        if didResign {
            clearPendingShortcutChordPrefixes()
        }
        return didResign
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown else {
            return super.performKeyEquivalent(with: event)
        }
        if handleEditorShortcut(event) {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func magnify(with event: NSEvent) {
        let factor = 1.0 + event.magnification
        guard factor.isFinite, factor > 0 else { return }
        adjustPreviewFontSize(by: factor)
    }

    override func scrollWheel(with event: NSEvent) {
        guard FilePreviewInteraction.hasZoomModifier(event) else {
            super.scrollWheel(with: event)
            return
        }
        adjustPreviewFontSize(by: FilePreviewInteraction.zoomFactor(forScroll: event))
    }

    override func smartMagnify(with event: NSEvent) {
        if abs(previewFontSize - configuredPreviewFontSize) < 0.0001 {
            _ = setPreviewFontSize(previewFontSize + 5)
        } else {
            _ = resetPreviewFontSize()
        }
    }

    @discardableResult
    func zoomPreviewFontIn() -> Bool {
        adjustPreviewFontSize(by: FilePreviewInteraction.zoomStep)
    }

    @discardableResult
    func zoomPreviewFontOut() -> Bool {
        adjustPreviewFontSize(by: 1 / FilePreviewInteraction.zoomStep)
    }

    @discardableResult
    func resetPreviewFontSize() -> Bool {
        setPreviewFontSize(configuredPreviewFontSize)
    }

    @discardableResult
    private func adjustPreviewFontSize(by factor: CGFloat) -> Bool {
        setPreviewFontSize(previewFontSize * factor)
    }

    @discardableResult
    private func setPreviewFontSize(_ nextFontSize: CGFloat) -> Bool {
        let clamped = CGFloat(FilePreviewFontSizeSettings.clamp(Double(nextFontSize)))
        guard clamped.isFinite else { return false }
        guard abs(clamped - previewFontSize) > 0.0001 else { return false }
        previewFontSize = clamped
        applyCurrentPreviewFont()
        return true
    }

    private func clearPendingShortcutChordPrefixes() {
        pendingEditorShortcutChordPrefix = nil
    }

    private func handleEditorShortcut(_ event: NSEvent) -> Bool {
        if hasMarkedText(),
           shortcutRoutingShouldBypassForPrintableOptionText(event: event) {
            clearPendingShortcutChordPrefixes()
            return false
        }

        let candidates = editorShortcutCandidates()
        if let pendingPrefix = pendingEditorShortcutChordPrefix {
            pendingEditorShortcutChordPrefix = nil
            for candidate in candidates {
                guard candidate.shortcut.firstStroke == pendingPrefix,
                      let secondStroke = candidate.shortcut.secondStroke,
                      secondStroke.matches(event: event) else { continue }
                guard candidate.isAllowed(event) else { return false }
                candidate.perform()
                return true
            }
            return false
        }

        for candidate in candidates {
            let shortcut = candidate.shortcut
            if shortcut.secondStroke != nil {
                if shortcut.firstStroke.matches(event: event) {
                    guard candidate.isAllowed(event) else { return false }
                    pendingEditorShortcutChordPrefix = shortcut.firstStroke
                    return true
                }
                continue
            }
            if shortcut.matches(event: event) {
                guard candidate.isAllowed(event) else { return false }
                candidate.perform()
                return true
            }
        }
        return false
    }

    private func editorShortcutCandidates() -> [
        (shortcut: StoredShortcut, isAllowed: (NSEvent) -> Bool, perform: () -> Void)
    ] {
        var candidates: [(shortcut: StoredShortcut, isAllowed: (NSEvent) -> Bool, perform: () -> Void)] = []
        let saveShortcut = KeyboardShortcutSettings.shortcut(for: .saveFilePreview)
        if !saveShortcut.isUnbound {
            candidates.append((saveShortcut, { _ in true }, { [weak self] in self?.panel?.saveTextContent() }))
        }
        for action in Self.previewFontZoomShortcutActions {
            let shortcut = KeyboardShortcutSettings.shortcut(for: action)
            guard !shortcut.isUnbound else { continue }
            candidates.append((
                shortcut,
                { [weak self] event in
                    self?.previewFontZoomShortcutWhenClauseAllows(action: action, event: event) ?? false
                },
                { [weak self] in self?.performPreviewFontZoomShortcutAction(action) }
            ))
        }
        return candidates
    }

    private func previewFontZoomShortcutWhenClauseAllows(
        action: KeyboardShortcutSettings.Action,
        event: NSEvent
    ) -> Bool {
        if window != nil, let appDelegate = AppDelegate.shared {
            return appDelegate.shortcutWhenClauseAllows(action: action, event: event)
        }
        return KeyboardShortcutSettings.effectiveWhenClause(for: action)
            .evaluate(Self.filePreviewTextEditorShortcutContext)
    }

    private static var filePreviewTextEditorShortcutContext: ShortcutContext {
        ShortcutFocusState(
            browser: false,
            markdown: false,
            sidebar: false,
            filePreviewTextEditor: true
        ).context
    }

    private func performPreviewFontZoomShortcutAction(_ action: KeyboardShortcutSettings.Action) {
        switch action {
        case .browserZoomIn:
            _ = zoomPreviewFontIn()
        case .browserZoomOut:
            _ = zoomPreviewFontOut()
        case .browserZoomReset:
            _ = resetPreviewFontSize()
        default:
            break
        }
    }
}

extension FilePreviewPanel {
    func attachTextView(_ textView: NSTextView) {
        self.textView = textView
        focusCoordinator.register(root: textView, primaryResponder: textView, intent: .textEditor)
    }

    @discardableResult
    func zoomTextPreviewIn() -> Bool {
        guard previewMode == .text,
              let textView = textView as? SavingTextView else { return false }
        return textView.zoomPreviewFontIn()
    }

    @discardableResult
    func zoomTextPreviewOut() -> Bool {
        guard previewMode == .text,
              let textView = textView as? SavingTextView else { return false }
        return textView.zoomPreviewFontOut()
    }

    @discardableResult
    func resetTextPreviewZoom() -> Bool {
        guard previewMode == .text,
              let textView = textView as? SavingTextView else { return false }
        return textView.resetPreviewFontSize()
    }
}
