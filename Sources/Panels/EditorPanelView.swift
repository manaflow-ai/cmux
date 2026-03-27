import AppKit
import SwiftUI

/// SwiftUI view that renders an EditorPanel using a native NSTextView.
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
                VStack(spacing: 0) {
                    editorHeader
                    Divider()
                    NativeTextEditor(panel: panel)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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

    // MARK: - Header

    private var editorHeader: some View {
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
            if panel.isDirty {
                Button(action: { panel.save() }) {
                    Text("Save")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Color.accentColor))
                }
                .buttonStyle(.plain)
                .help("Save file (Cmd+S)")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(colorScheme == .dark
            ? Color(nsColor: NSColor(white: 0.15, alpha: 1.0))
            : Color(nsColor: NSColor(white: 0.96, alpha: 1.0)))
    }

    // MARK: - Unavailable

    private var fileUnavailableView: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.questionmark")
                .font(.system(size: 40))
                .foregroundColor(.secondary)
            Text("File unavailable")
                .font(.headline)
                .foregroundColor(.primary)
            Text(panel.filePath)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
                .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Focus Flash

    private func triggerFocusFlashAnimation() {
        focusFlashAnimationGeneration &+= 1
        let generation = focusFlashAnimationGeneration
        focusFlashOpacity = FocusFlashPattern.values.first ?? 0

        for segment in FocusFlashPattern.segments {
            DispatchQueue.main.asyncAfter(deadline: .now() + segment.delay) {
                guard focusFlashAnimationGeneration == generation else { return }
                let animation: Animation = segment.curve == .easeIn
                    ? .easeIn(duration: segment.duration)
                    : .easeOut(duration: segment.duration)
                withAnimation(animation) {
                    focusFlashOpacity = segment.targetOpacity
                }
            }
        }
    }
}

// MARK: - Native NSTextView wrapper

/// Wraps an NSTextView in SwiftUI for code editing.
/// Supports monospace font, Cmd+S save, and two-way text binding.
struct NativeTextEditor: NSViewRepresentable {
    @ObservedObject var panel: EditorPanel

    func makeCoordinator() -> Coordinator {
        Coordinator(panel: panel)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

        let textView = SaveableTextView()
        textView.onSave = { [weak panel] in
            panel?.save()
        }

        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.usesFindBar = true

        // Monospace font
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.font = font
        textView.typingAttributes = [.font: font]

        // No line wrapping — horizontal scroll
        textView.isHorizontallyResizable = true
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)

        // Appearance — match terminal dark/light mode
        textView.drawsBackground = true
        textView.textContainerInset = NSSize(width: 8, height: 8)
        applyTheme(to: textView, scrollView: scrollView)

        // Set initial content with syntax highlighting
        let fileExt = (panel.filePath as NSString).pathExtension
        let isDark = textView.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            || textView.window == nil
        let highlighted = SyntaxHighlighter.highlight(panel.content, fileExtension: fileExt, isDark: isDark)
        textView.textStorage?.setAttributedString(highlighted)

        textView.delegate = context.coordinator
        context.coordinator.fileExtension = fileExt

        scrollView.documentView = textView
        context.coordinator.textView = textView

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        // Only update if text changed externally (not from user typing)
        if textView.string != panel.content && !context.coordinator.isUpdatingFromTextView {
            textView.string = panel.content
        }
        // Reapply theme on appearance change (dark/light mode switch)
        applyTheme(to: textView, scrollView: scrollView)
    }

    /// Apply background/insertion point colors (not text — syntax highlighter handles that).
    private func applyTheme(to textView: NSTextView, scrollView: NSScrollView) {
        let isDark = textView.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            || textView.window == nil
        let bgColor = isDark
            ? NSColor(white: 0.12, alpha: 1.0)
            : NSColor(white: 0.98, alpha: 1.0)

        textView.backgroundColor = bgColor
        textView.insertionPointColor = isDark ? .white : .black
        scrollView.backgroundColor = bgColor
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, NSTextViewDelegate {
        let panel: EditorPanel
        weak var textView: NSTextView?
        var isUpdatingFromTextView = false
        var isHighlighting = false
        var fileExtension: String = ""
        private var highlightWorkItem: DispatchWorkItem?

        init(panel: EditorPanel) {
            self.panel = panel
        }

        func textDidChange(_ notification: Notification) {
            // Skip if this was triggered by syntax re-highlighting (not user typing)
            guard !isHighlighting else { return }
            guard let textView = notification.object as? NSTextView else { return }
            isUpdatingFromTextView = true
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.panel.content = textView.string
                self.panel.textDidChange()
                self.isUpdatingFromTextView = false
            }
            // Debounced re-highlight (300ms after last keystroke)
            scheduleHighlight(for: textView)
        }

        private func scheduleHighlight(for textView: NSTextView) {
            highlightWorkItem?.cancel()
            let ext = fileExtension
            let workItem = DispatchWorkItem { [weak self, weak textView] in
                guard let textView else { return }
                Task { @MainActor in
                    guard let self else { return }
                    let isDark = textView.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                        || textView.window == nil
                    let selectedRange = textView.selectedRange()
                    let highlighted = SyntaxHighlighter.highlight(textView.string, fileExtension: ext, isDark: isDark)
                    // Mark as highlighting so textDidChange ignores this mutation
                    self.isHighlighting = true
                    textView.textStorage?.beginEditing()
                    textView.textStorage?.setAttributedString(highlighted)
                    textView.textStorage?.endEditing()
                    self.isHighlighting = false
                    // Restore cursor position
                    let safeRange = NSRange(
                        location: min(selectedRange.location, textView.string.count),
                        length: 0
                    )
                    textView.setSelectedRange(safeRange)
                }
            }
            highlightWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: workItem)
        }
    }
}

// MARK: - NSTextView subclass with Cmd+S

/// NSTextView subclass that intercepts Cmd+S to trigger save.
/// Uses both performKeyEquivalent AND a local event monitor to catch
/// Cmd+S even when CMUX's menu system consumes key equivalents.
final class SaveableTextView: NSTextView {
    var onSave: (() -> Void)?
    private var eventMonitor: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil && eventMonitor == nil {
            eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self,
                      self.window?.firstResponder === self,
                      event.modifierFlags.contains(.command),
                      event.charactersIgnoringModifiers == "s" else {
                    return event
                }
                self.onSave?()
                return nil  // Consume the event
            }
        }
    }

    deinit {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers == "s" {
            onSave?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
