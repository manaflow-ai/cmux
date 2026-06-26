import AppKit
import CmuxFoundation
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
    /// Whether long lines soft-wrap at the editor's right edge. Sourced from
    /// the persisted `fileEditor.wordWrap` setting; updates apply live.
    let wordWrap: Bool
    /// Highlighting language for the open file, or `nil` for unsupported file
    /// types (which render as plain text, as before).
    let syntaxLanguage: FilePreviewSyntaxLanguage?
    /// Whether syntax highlighting is enabled. Sourced from the persisted
    /// `fileEditor.syntaxHighlighting` setting; updates apply live.
    let syntaxHighlightingEnabled: Bool

    /// Chooses the dark or light token palette from the editor's foreground
    /// color, which is reliable even when the content background is `.clear`.
    private var prefersDarkSyntaxPalette: Bool {
        FilePreviewSyntaxTheme.prefersDarkPalette(foreground: themeForegroundColor)
    }

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

        let textView = SavingTextView.makeFilePreviewTextView()
        textView.panel = panel
        textView.delegate = context.coordinator
        textView.drawsBackground = drawsBackground
        textView.string = panel.textContent
        panel.attachTextView(textView)

        scrollView.documentView = textView
        textView.applyFilePreviewWordWrap(wordWrap, scrollView: scrollView)
        Self.applyTheme(
            to: scrollView,
            backgroundColor: themeBackgroundColor,
            foregroundColor: themeForegroundColor,
            drawsBackground: drawsBackground
        )
        textView.configureSyntaxHighlighting(
            language: syntaxLanguage,
            prefersDarkPalette: prefersDarkSyntaxPalette,
            enabled: syntaxHighlightingEnabled
        )
        textView.refreshSyntaxHighlighting()
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
        textView.applyFilePreviewWordWrap(wordWrap, scrollView: scrollView)
        panel.attachTextView(textView)

        let highlightConfigChanged = textView.configureSyntaxHighlighting(
            language: syntaxLanguage,
            prefersDarkPalette: prefersDarkSyntaxPalette,
            enabled: syntaxHighlightingEnabled
        )

        let textChanged = textView.string != panel.textContent
        if textChanged {
            context.coordinator.isApplyingPanelUpdate = true
            textView.string = panel.textContent
            context.coordinator.isApplyingPanelUpdate = false
        }

        // Programmatic `string` assignments and config/theme changes do not fire
        // `didChangeText()`, so re-highlight explicitly when either occurs.
        if textChanged || highlightConfigChanged {
            textView.refreshSyntaxHighlighting()
        }
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

        deinit {}

        func textDidChange(_ notification: Notification) {
            guard !isApplyingPanelUpdate,
                  let textView = notification.object as? NSTextView else { return }
            panel.updateTextContent(textView.string)
        }
    }
}

enum FilePreviewTextEditorLayout {
    static let textContainerInset = NSSize(width: 12, height: 10)
    static let lineFragmentPadding: CGFloat = 0
}

extension SavingTextView {
    /// Builds the File Preview text view configured for large plain-text files.
    ///
    /// File Preview opens files up to `FilePreviewPanel.maximumLoadedTextBytes` (16 MB), which can
    /// be hundreds of thousands of lines. Selection responsiveness on that content is the reason
    /// this configuration is centralized; see `manaflow-ai/cmux#4576`.
    static func makeFilePreviewTextView() -> SavingTextView {
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
        textView.applyCurrentPreviewFont()
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
        let targetInset = FilePreviewTextEditorLayout.textContainerInset
        if textContainerInset.width != targetInset.width || textContainerInset.height != targetInset.height {
            textContainerInset = targetInset
        }
        if textContainer?.lineFragmentPadding != FilePreviewTextEditorLayout.lineFragmentPadding {
            textContainer?.lineFragmentPadding = FilePreviewTextEditorLayout.lineFragmentPadding
        }
    }
}

final class SavingTextView: NSTextView {
    private static let defaultPreviewFontSize: CGFloat = 13
    private static let minimumPreviewFontSize: CGFloat = 8
    private static let maximumPreviewFontSize: CGFloat = 36

    weak var panel: (any FilePreviewTextEditingPanel)?
    private var previewFontSize: CGFloat = 13
    private var pendingSaveShortcutChordPrefix: ShortcutStroke?
    private var fontMagnificationObserver: GlobalFontMagnificationChangeObserver?

    private var syntaxLanguage: FilePreviewSyntaxLanguage?
    private var syntaxPrefersDarkPalette = true
    private var syntaxHighlightingEnabled = FilePreviewSyntaxHighlightSettings.defaultEnabled
    private var syntaxHighlightGeneration = 0
    private var pendingSyntaxHighlightTask: Task<Void, Never>?

    /// Files larger than this skip highlighting and render as plain text, keeping
    /// the large-document performance contract (see ``makeFilePreviewTextView``).
    private static let maximumHighlightedUTF16Length = 600_000
    /// Coalesces re-highlighting after rapid edits so typing stays responsive.
    private static let syntaxHighlightDebounceNanoseconds: UInt64 = 180_000_000

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
        applyFilePreviewTextEditorInsets()
        panel?.retryPendingFocus()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown else {
            return super.performKeyEquivalent(with: event)
        }
        guard let shouldSave = saveShortcutMatch(for: event) else {
            return super.performKeyEquivalent(with: event)
        }
        if shouldSave {
            panel?.saveTextContent()
        }
        return true
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
        if previewFontSize == Self.defaultPreviewFontSize {
            setPreviewFontSize(18)
        } else {
            setPreviewFontSize(Self.defaultPreviewFontSize)
        }
    }

    private func adjustPreviewFontSize(by factor: CGFloat) {
        setPreviewFontSize(previewFontSize * factor)
    }

    private func setPreviewFontSize(_ nextFontSize: CGFloat) {
        let clamped = min(max(nextFontSize, Self.minimumPreviewFontSize), Self.maximumPreviewFontSize)
        guard clamped.isFinite else { return }
        previewFontSize = clamped
        applyCurrentPreviewFont()
    }

    func applyCurrentPreviewFont() {
        let nextFont = GlobalFontMagnification.monospacedSystemFont(ofSize: previewFontSize, weight: .regular)
        font = nextFont
        typingAttributes[.font] = nextFont
    }

    override func didChangeText() {
        super.didChangeText()
        scheduleSyntaxHighlightRefresh()
    }

    // MARK: - Syntax highlighting

    /// Updates the highlighting inputs. Returns `true` when any of them changed,
    /// so the caller can trigger a refresh only when needed.
    @discardableResult
    func configureSyntaxHighlighting(
        language: FilePreviewSyntaxLanguage?,
        prefersDarkPalette: Bool,
        enabled: Bool
    ) -> Bool {
        let changed = language != syntaxLanguage
            || prefersDarkPalette != syntaxPrefersDarkPalette
            || enabled != syntaxHighlightingEnabled
        syntaxLanguage = language
        syntaxPrefersDarkPalette = prefersDarkPalette
        syntaxHighlightingEnabled = enabled
        return changed
    }

    /// Recomputes tokens off the main thread (the only expensive step) and
    /// applies display-only color via the layout manager's temporary attributes,
    /// which never mutate the text storage, undo stack, or font.
    func refreshSyntaxHighlighting() {
        pendingSyntaxHighlightTask?.cancel()
        pendingSyntaxHighlightTask = nil
        syntaxHighlightGeneration &+= 1
        let generation = syntaxHighlightGeneration

        guard syntaxHighlightingEnabled, let language = syntaxLanguage else {
            clearSyntaxHighlighting()
            return
        }
        guard (string as NSString).length <= Self.maximumHighlightedUTF16Length else {
            clearSyntaxHighlighting()
            return
        }

        let source = string
        let prefersDark = syntaxPrefersDarkPalette
        pendingSyntaxHighlightTask = Task { [weak self] in
            let tokens = await Task.detached(priority: .userInitiated) {
                FilePreviewSyntaxTokenizer.tokens(in: source, language: language)
            }.value
            guard !Task.isCancelled,
                  let self,
                  self.syntaxHighlightGeneration == generation else { return }
            self.applySyntaxTokens(tokens, prefersDark: prefersDark)
        }
    }

    private func scheduleSyntaxHighlightRefresh() {
        pendingSyntaxHighlightTask?.cancel()
        pendingSyntaxHighlightTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.syntaxHighlightDebounceNanoseconds)
            guard !Task.isCancelled, let self else { return }
            self.refreshSyntaxHighlighting()
        }
    }

    private func applySyntaxTokens(_ tokens: [FilePreviewSyntaxToken], prefersDark: Bool) {
        // Reach the layout manager through the text container so we never touch
        // the `.layoutManager` accessor that would flip an otherwise TextKit 1
        // view into TextKit 2 compatibility mode (see ``makeFilePreviewTextView``).
        guard let layoutManager = textContainer?.layoutManager else { return }
        let theme = FilePreviewSyntaxTheme.theme(prefersDark: prefersDark)
        let length = (string as NSString).length
        let fullRange = NSRange(location: 0, length: length)
        layoutManager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: fullRange)
        for token in tokens {
            let range = token.range
            guard range.length > 0,
                  range.location >= 0,
                  range.location + range.length <= length else { continue }
            layoutManager.addTemporaryAttributes(
                [.foregroundColor: theme.color(for: token.kind)],
                forCharacterRange: range
            )
        }
    }

    private func clearSyntaxHighlighting() {
        guard let layoutManager = textContainer?.layoutManager else { return }
        let length = (string as NSString).length
        layoutManager.removeTemporaryAttribute(
            .foregroundColor,
            forCharacterRange: NSRange(location: 0, length: length)
        )
    }

    private func saveShortcutMatch(for event: NSEvent) -> Bool? {
        let shortcut = KeyboardShortcutSettings.shortcut(for: .saveFilePreview)
        guard shortcut.hasChord else {
            pendingSaveShortcutChordPrefix = nil
            return shortcut.matches(event: event) ? true : nil
        }

        if let pendingPrefix = pendingSaveShortcutChordPrefix {
            pendingSaveShortcutChordPrefix = nil
            guard pendingPrefix == shortcut.firstStroke,
                  let secondStroke = shortcut.secondStroke else {
                return nil
            }
            return secondStroke.matches(event: event) ? true : nil
        }

        if shortcut.firstStroke.matches(event: event) {
            pendingSaveShortcutChordPrefix = shortcut.firstStroke
            return false
        }
        return nil
    }
}
