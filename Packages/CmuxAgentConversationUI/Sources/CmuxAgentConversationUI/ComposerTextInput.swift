import Foundation
import SwiftUI

#if canImport(AppKit)
import AppKit

/// The composer's multi-line text input on macOS.
///
/// Backed by `NSTextView` so key routing is deterministic: plain Return
/// submits, Shift+Return inserts a newline (SwiftUI's `onKeyPress` does not
/// reliably intercept field-editor keys across the supported macOS range).
/// The view auto-grows with its content up to a few lines, then scrolls.
struct ComposerTextInput: NSViewRepresentable {
    /// The composed text.
    @Binding var text: String

    /// Called when the user submits with plain Return.
    let onSubmit: () -> Void

    func makeNSView(context: Context) -> ComposerScrollView {
        let textView = NSTextView()
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = .systemFont(ofSize: NSFont.systemFontSize)
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 0, height: 4)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.setAccessibilityLabel(
            String(localized: "agentChat.composer.accessibilityLabel", defaultValue: "Message input", bundle: .module)
        )

        let scrollView = ComposerScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.verticalScrollElasticity = .none
        return scrollView
    }

    func updateNSView(_ scrollView: ComposerScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? NSTextView else { return }
        if textView.string != text {
            textView.string = text
            scrollView.invalidateIntrinsicContentSize()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    /// Bridges `NSTextViewDelegate` events back into SwiftUI state.
    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        /// The current representable value (refreshed on every update pass).
        var parent: ComposerTextInput

        init(parent: ComposerTextInput) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
            textView.enclosingScrollView?.invalidateIntrinsicContentSize()
        }

        func textView(
            _ textView: NSTextView,
            doCommandBy commandSelector: Selector
        ) -> Bool {
            guard commandSelector == #selector(NSResponder.insertNewline(_:)) else { return false }
            // Shift+Return falls through to the default newline insertion;
            // plain Return submits the composed text.
            if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                return false
            }
            parent.onSubmit()
            return true
        }
    }
}

#else

/// The composer's multi-line text input on platforms without AppKit.
///
/// A vertically expanding `TextField`; the software keyboard's return key
/// submits via `onSubmit` (hardware Shift+Return handling is a macOS concern).
struct ComposerTextInput: View {
    /// The composed text.
    @Binding var text: String

    /// Called when the user submits.
    let onSubmit: () -> Void

    var body: some View {
        TextField(
            String(localized: "agentChat.composer.accessibilityLabel", defaultValue: "Message input", bundle: .module),
            text: $text,
            axis: .vertical
        )
        .textFieldStyle(.plain)
        .lineLimit(1...6)
        .onSubmit(onSubmit)
    }
}

#endif
