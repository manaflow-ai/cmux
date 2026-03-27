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
                Text("Modified")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.orange)
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

        // Set initial content
        textView.string = panel.content
        textView.delegate = context.coordinator

        scrollView.documentView = textView
        context.coordinator.textView = textView

        NSLog("EditorPanel: NSTextView created, content length: \(panel.content.count)")
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

    /// Apply theme colors matching the terminal.
    /// Uses the window's effective appearance (falls back to dark).
    private func applyTheme(to textView: NSTextView, scrollView: NSScrollView) {
        let isDark = textView.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            || textView.window == nil  // Before window attachment, assume dark (terminal default)
        let bgColor = isDark
            ? NSColor(white: 0.12, alpha: 1.0)
            : NSColor(white: 0.98, alpha: 1.0)
        let fgColor = isDark
            ? NSColor(white: 0.9, alpha: 1.0)
            : NSColor(white: 0.1, alpha: 1.0)

        textView.backgroundColor = bgColor
        textView.insertionPointColor = isDark ? .white : .black
        scrollView.backgroundColor = bgColor

        // Update text color for existing content + future typing
        textView.textColor = fgColor
        if let font = textView.font {
            textView.typingAttributes = [.font: font, .foregroundColor: fgColor]
        }
        // Recolor existing text
        if textView.string.count > 0 {
            textView.textStorage?.addAttribute(
                .foregroundColor, value: fgColor,
                range: NSRange(location: 0, length: textView.string.count)
            )
        }
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, NSTextViewDelegate {
        let panel: EditorPanel
        weak var textView: NSTextView?
        var isUpdatingFromTextView = false

        init(panel: EditorPanel) {
            self.panel = panel
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            isUpdatingFromTextView = true
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.panel.content = textView.string
                self.panel.textDidChange()
                self.isUpdatingFromTextView = false
            }
        }
    }
}

// MARK: - NSTextView subclass with Cmd+S

/// NSTextView subclass that intercepts Cmd+S to trigger save.
final class SaveableTextView: NSTextView {
    var onSave: (() -> Void)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers == "s" {
            NSLog("EditorPanel: Cmd+S pressed")
            onSave?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
