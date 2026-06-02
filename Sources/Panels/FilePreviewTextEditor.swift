import AppKit
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
        guard textView.string != panel.textContent else { return }
        context.coordinator.isApplyingPanelUpdate = true
        textView.string = panel.textContent
        context.coordinator.isApplyingPanelUpdate = false
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
        let textView = SavingTextView()
        // Must run before any `textContainer` access below, or the view locks into TextKit 2.
        textView.enableLargeDocumentSelectionPerformance()
        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.usesFindPanel = true
        textView.usesFontPanel = false
        textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.widthTracksTextView = false
        textView.applyFilePreviewTextEditorInsets()
        return textView
    }
}

extension NSTextView {
    /// Drops the text view to TextKit 1 with non-contiguous layout for large-document performance.
    ///
    /// TextKit 2's `NSTextSelectionNavigation` hit-tests are O(N) in line-fragment count, so
    /// drag-selecting deep into a large file pegs the main thread (`manaflow-ai/cmux#4576`).
    /// Accessing `layoutManager` puts the view in TextKit 1 compatibility mode, where mouse
    /// hit-testing is roughly O(log N); `allowsNonContiguousLayout` keeps glyph layout lazy so
    /// large files still open instantly.
    ///
    /// Call this before touching `textContainer`/`textLayoutManager` on a freshly created text
    /// view, otherwise the first TextKit 2 access locks the view into TextKit 2 and
    /// `layoutManager` returns `nil`.
    func enableLargeDocumentSelectionPerformance() {
        guard let layoutManager else {
            // `layoutManager` is nil only when a TextKit 2 access already locked the view into
            // TextKit 2, in which case non-contiguous layout was never enabled and large-document
            // selection regresses to O(N). Release behavior is unchanged (no-op); DEBUG fails loudly
            // so the call-order violation is caught at its source rather than as a future hang.
            assertionFailure(
                "enableLargeDocumentSelectionPerformance() ran after a TextKit 2 access; "
                    + "call it before touching textContainer/textLayoutManager."
            )
            return
        }
        layoutManager.allowsNonContiguousLayout = true
    }

    /// Configures the text view and its scroll view for soft line wrapping
    /// (`wrap == true`) or the no-wrap baseline with a horizontal scroller
    /// (`wrap == false`). Idempotent, so it is safe to call on every SwiftUI
    /// update; toggling the `fileEditor.wordWrap` setting reflows open editors.
    func applyFilePreviewWordWrap(_ wrap: Bool, scrollView: NSScrollView) {
        guard let textContainer else { return }
        scrollView.hasHorizontalScroller = !wrap
        isHorizontallyResizable = !wrap
        if wrap {
            let visibleWidth = scrollView.contentSize.width
            textContainer.widthTracksTextView = true
            textContainer.size = NSSize(width: visibleWidth, height: .greatestFiniteMagnitude)
            // Snap the view to the visible width so wrapping reflows immediately
            // instead of waiting for the next layout pass.
            setFrameSize(NSSize(width: visibleWidth, height: frame.height))
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

    deinit {}

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
        let nextFont = NSFont.monospacedSystemFont(ofSize: clamped, weight: .regular)
        font = nextFont
        typingAttributes[.font] = nextFont
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
