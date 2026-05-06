import AppKit
import SwiftUI

struct FilePreviewTextEditor: NSViewRepresentable {
    @ObservedObject var panel: FilePreviewPanel
    let isVisibleInUI: Bool
    let themeBackgroundColor: NSColor
    let themeForegroundColor: NSColor

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
        scrollView.drawsBackground = true

        let textView = SavingTextView()
        textView.panel = panel
        textView.delegate = context.coordinator
        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.usesFindPanel = true
        textView.usesFontPanel = false
        textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.drawsBackground = true
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
        textView.string = panel.textContent
        panel.attachTextView(textView)

        scrollView.documentView = textView
        Self.applyTheme(to: scrollView, backgroundColor: themeBackgroundColor, foregroundColor: themeForegroundColor)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.panel = panel
        scrollView.isHidden = !isVisibleInUI
        Self.applyTheme(to: scrollView, backgroundColor: themeBackgroundColor, foregroundColor: themeForegroundColor)
        guard let textView = scrollView.documentView as? SavingTextView else { return }
        textView.panel = panel
        textView.applyFilePreviewTextEditorInsets()
        panel.attachTextView(textView)
        guard textView.string != panel.textContent else { return }
        context.coordinator.isApplyingPanelUpdate = true
        textView.string = panel.textContent
        context.coordinator.isApplyingPanelUpdate = false
    }

    private static func applyTheme(
        to scrollView: NSScrollView,
        backgroundColor: NSColor,
        foregroundColor: NSColor
    ) {
        scrollView.backgroundColor = backgroundColor
        scrollView.contentView.backgroundColor = backgroundColor
        if let textView = scrollView.documentView as? NSTextView {
            textView.backgroundColor = backgroundColor
            textView.textColor = foregroundColor
            textView.insertionPointColor = foregroundColor
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var panel: FilePreviewPanel
        var isApplyingPanelUpdate = false

        init(panel: FilePreviewPanel) {
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

extension NSTextView {
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

    weak var panel: FilePreviewPanel?
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
