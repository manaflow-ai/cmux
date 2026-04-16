import AppKit
import SwiftUI

/// SwiftUI view that hosts an NSTextView-based text editor for an EditorPanel.
struct EditorPanelView: View {
    @ObservedObject var panel: EditorPanel
    let isFocused: Bool
    let isVisibleInUI: Bool
    let portalPriority: Int
    let onRequestPanelFocus: () -> Void

    @State private var focusFlashOpacity: Double = 0.0
    @State private var focusFlashAnimationGeneration: Int = 0
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Group {
            if panel.isFileUnavailable {
                fileUnavailableView
            } else {
                editorContentView
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(backgroundColor)
        .overlay {
            RoundedRectangle(cornerRadius: FocusFlashPattern.ringCornerRadius)
                .stroke(cmuxAccentColor().opacity(focusFlashOpacity), lineWidth: 3)
                .shadow(color: cmuxAccentColor().opacity(focusFlashOpacity * 0.35), radius: 10)
                .padding(FocusFlashPattern.ringInset)
                .allowsHitTesting(false)
        }
        .onChange(of: panel.focusFlashToken) { _ in
            triggerFocusFlashAnimation()
        }
    }

    // MARK: - Content

    private var editorContentView: some View {
        VStack(spacing: 0) {
            filePathHeader
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 6)
            Divider()
                .padding(.horizontal, 8)
            EditorTextViewRepresentable(
                panel: panel,
                isFocused: isFocused,
                onRequestPanelFocus: onRequestPanelFocus
            )
        }
    }

    private var filePathHeader: some View {
        HStack(spacing: 6) {
            Image(systemName: "doc.text")
                .foregroundColor(.secondary)
                .font(.system(size: 12))
            Text(panel.filePath)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
        }
    }

    private var fileUnavailableView: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.questionmark")
                .font(.system(size: 40))
                .foregroundColor(.secondary)
            Text(String(localized: "editor.fileUnavailable.title", defaultValue: "File unavailable"))
                .font(.headline)
                .foregroundColor(.primary)
            Text(panel.filePath)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 24)
            Text(String(localized: "editor.fileUnavailable.message", defaultValue: "The file may have been moved or deleted."))
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Theme

    private var backgroundColor: Color {
        colorScheme == .dark
            ? Color(nsColor: NSColor(white: 0.12, alpha: 1.0))
            : Color(nsColor: NSColor(white: 0.98, alpha: 1.0))
    }

    // MARK: - Focus Flash

    private func triggerFocusFlashAnimation() {
        focusFlashAnimationGeneration &+= 1
        let generation = focusFlashAnimationGeneration
        focusFlashOpacity = FocusFlashPattern.values.first ?? 0

        for segment in FocusFlashPattern.segments {
            DispatchQueue.main.asyncAfter(deadline: .now() + segment.delay) {
                guard focusFlashAnimationGeneration == generation else { return }
                withAnimation(focusFlashAnimation(for: segment.curve, duration: segment.duration)) {
                    focusFlashOpacity = segment.targetOpacity
                }
            }
        }
    }

    private func focusFlashAnimation(for curve: FocusFlashCurve, duration: TimeInterval) -> Animation {
        switch curve {
        case .easeIn:
            return .easeIn(duration: duration)
        case .easeOut:
            return .easeOut(duration: duration)
        }
    }
}

// MARK: - NSTextView Bridge

private struct EditorTextViewRepresentable: NSViewRepresentable {
    let panel: EditorPanel
    let isFocused: Bool
    let onRequestPanelFocus: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(panel: panel, onRequestPanelFocus: onRequestPanelFocus)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        let textView = EditorNSTextView()
        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.isRichText = false
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticTextCompletionEnabled = false
        textView.smartInsertDeleteEnabled = false

        textView.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.textContainerInset = NSSize(width: 16, height: 12)
        textView.autoresizingMask = [.width]
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: scrollView.contentSize.width,
            height: CGFloat.greatestFiniteMagnitude
        )

        applyThemeColors(to: textView)

        textView.string = panel.content
        textView.delegate = context.coordinator
        textView.editorPanel = panel
        textView.onRequestPanelFocus = onRequestPanelFocus

        // Restore persisted cursor position, clamped to the current content length.
        let totalLength = (textView.string as NSString).length
        let location = min(max(panel.cursorLocation, 0), totalLength)
        let length = min(max(panel.cursorLength, 0), totalLength - location)
        textView.selectedRange = NSRange(location: location, length: length)
        let restoreFraction = panel.scrollTopFraction
        DispatchQueue.main.async { [weak scrollView, weak textView] in
            guard let scrollView, let textView else { return }
            if restoreFraction > 0, let doc = scrollView.documentView {
                // Prefer the persisted scroll fraction over the cursor reveal so
                // reopening a tab returns the viewport to where the user left it.
                let contentHeight = scrollView.contentView.bounds.height
                let docHeight = doc.bounds.height
                let maxOffset = max(0, docHeight - contentHeight)
                let offsetY = min(maxOffset, max(0, restoreFraction * maxOffset))
                scrollView.contentView.scroll(to: NSPoint(x: 0, y: offsetY))
                scrollView.reflectScrolledClipView(scrollView.contentView)
            } else {
                textView.scrollRangeToVisible(NSRange(location: location, length: 0))
            }
        }

        context.coordinator.attachScrollObserver(for: scrollView)

        scrollView.documentView = textView
        context.coordinator.textView = textView
        panel.textView = textView

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? EditorNSTextView else { return }

        context.coordinator.panel = panel
        context.coordinator.onRequestPanelFocus = onRequestPanelFocus
        textView.editorPanel = panel
        textView.onRequestPanelFocus = onRequestPanelFocus
        panel.textView = textView

        // Only update text if it differs and we're not mid-edit
        if !context.coordinator.isEditing && textView.string != panel.content {
            let savedRanges = textView.selectedRanges
            textView.string = panel.content
            // Clamp ranges to new content length. Without this, AppKit throws
            // NSRangeException when an external change shrinks the file.
            let newLength = (textView.string as NSString).length
            let clamped = savedRanges.compactMap { value -> NSValue? in
                let range = value.rangeValue
                let loc = min(range.location, newLength)
                let remaining = newLength - loc
                let len = min(range.length, remaining)
                return NSValue(range: NSRange(location: loc, length: len))
            }
            if !clamped.isEmpty {
                textView.selectedRanges = clamped
            }
        }

        applyThemeColors(to: textView)
    }

    private func applyThemeColors(to textView: NSTextView) {
        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        textView.backgroundColor = isDark
            ? NSColor(white: 0.12, alpha: 1.0)
            : NSColor(white: 0.98, alpha: 1.0)
        textView.textColor = isDark
            ? NSColor(white: 0.9, alpha: 1.0)
            : NSColor(white: 0.1, alpha: 1.0)
        textView.insertionPointColor = isDark
            ? .white
            : .black
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var panel: EditorPanel
        var onRequestPanelFocus: () -> Void
        weak var textView: NSTextView?
        var isEditing: Bool = false
        private weak var observedScrollView: NSScrollView?
        private var scrollObserver: Any?

        init(panel: EditorPanel, onRequestPanelFocus: @escaping () -> Void) {
            self.panel = panel
            self.onRequestPanelFocus = onRequestPanelFocus
        }

        deinit {
            if let observer = scrollObserver {
                NotificationCenter.default.removeObserver(observer)
            }
        }

        func attachScrollObserver(for scrollView: NSScrollView) {
            if let existing = scrollObserver {
                NotificationCenter.default.removeObserver(existing)
                scrollObserver = nil
            }
            observedScrollView = scrollView
            scrollView.contentView.postsBoundsChangedNotifications = true
            scrollObserver = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: scrollView.contentView,
                queue: .main
            ) { [weak self] _ in
                self?.updateScrollFractionIfNeeded()
            }
        }

        private func updateScrollFractionIfNeeded() {
            guard let scrollView = observedScrollView,
                  let doc = scrollView.documentView else { return }
            let contentHeight = scrollView.contentView.bounds.height
            let docHeight = doc.bounds.height
            let maxOffset = max(0, docHeight - contentHeight)
            guard maxOffset > 0 else {
                panel.scrollTopFraction = 0
                return
            }
            let offsetY = scrollView.contentView.bounds.origin.y
            let clamped = min(1, max(0, offsetY / maxOffset))
            if abs(panel.scrollTopFraction - clamped) > 0.0005 {
                panel.scrollTopFraction = clamped
                panel.lastOpenedAt = Date().timeIntervalSince1970
            }
        }

        func textDidBeginEditing(_ notification: Notification) {
            isEditing = true
        }

        func textDidEndEditing(_ notification: Notification) {
            isEditing = false
            panel.content = textView?.string ?? panel.content
            panel.markDirty()
        }

        func textDidChange(_ notification: Notification) {
            panel.content = textView?.string ?? panel.content
            panel.markDirty()
        }

        func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
            // Tab-to-2-spaces
            if let replacement = replacementString, replacement == "\t" {
                textView.insertText("  ", replacementRange: affectedCharRange)
                return false
            }
            return true
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            let range = textView.selectedRange()
            panel.cursorLocation = range.location
            panel.cursorLength = range.length
        }
    }
}

// MARK: - Custom NSTextView subclass for Cmd+S

private final class EditorNSTextView: NSTextView {
    weak var editorPanel: EditorPanel?
    var onRequestPanelFocus: (() -> Void)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if KeyboardShortcutSettings.shortcut(for: .saveEditorFile).matches(event: event) {
            guard let panel = editorPanel else { return true }
            // `save()` only surfaces failures through its return value; swallowing
            // it would let users believe a read-only/permission-denied/disk-full
            // write succeeded. Show the same alert the close-dialog path uses.
            if panel.isDirty, !panel.save() {
                EditorSaveAlert.show(for: panel)
            }
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        onRequestPanelFocus?()
        super.mouseDown(with: event)
    }
}

// MARK: - Save-failure alert

/// Visually matches `Workspace.showEditorSaveFailureAlert(for:)` so both the
/// close-time dialog and the Cmd+S shortcut surface save failures identically.
enum EditorSaveAlert {
    @MainActor
    static func show(for editorPanel: EditorPanel) {
        let alert = NSAlert()
        let filename = (editorPanel.filePath as NSString).lastPathComponent
        let failedTitleFormat = String(
            localized: "editor.saveFailed.title",
            defaultValue: "Could not save \"%@\""
        )
        alert.messageText = String(format: failedTitleFormat, filename)
        alert.informativeText = String(
            localized: "editor.saveFailed.message",
            defaultValue: "The file may be read-only or the disk may be full. Your changes remain in the editor."
        )
        alert.alertStyle = .warning
        alert.addButton(withTitle: String(localized: "editor.saveFailed.ok", defaultValue: "OK"))
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            alert.beginSheetModal(for: window, completionHandler: nil)
        } else {
            alert.runModal()
        }
    }
}
