import AppKit
import SwiftUI

struct PromptTextEditor: NSViewRepresentable {
    @Binding var text: String
    var isEditable: Bool = true
    var onSubmit: (() -> Void)?

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        guard let tv = scrollView.documentView as? NSTextView else { return scrollView }
        tv.delegate = context.coordinator
        tv.font = .systemFont(ofSize: 12)
        tv.isRichText = false
        tv.drawsBackground = false
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.textContainerInset = NSSize(width: 4, height: 4)
        tv.textContainer?.lineFragmentPadding = 4
        tv.textContainer?.widthTracksTextView = true
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let tv = scrollView.documentView as? NSTextView else { return }
        if tv.string != text { tv.string = text }
        if tv.isEditable != isEditable { tv.isEditable = isEditable }
        let targetColor: NSColor = isEditable ? .labelColor : .placeholderTextColor
        if tv.textColor != targetColor { tv.textColor = targetColor }
        context.coordinator.parent = self
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: PromptTextEditor

        init(parent: PromptTextEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            parent.text = tv.string
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if selector == #selector(NSTextView.insertNewline(_:)) {
                parent.onSubmit?()
                return true
            }
            return false
        }
    }
}

struct PromptTextEditorContainer: View {
    @Binding var text: String
    let placeholder: String
    var isEditable: Bool = true
    var onSubmit: (() -> Void)?

    var body: some View {
        ZStack(alignment: .topLeading) {
            if text.isEmpty {
                Text(placeholder)
                    .font(.system(size: 12))
                    .foregroundColor(Color(NSColor.placeholderTextColor))
                    .padding(.leading, 9)
                    .padding(.top, 7)
                    .allowsHitTesting(false)
            }
            PromptTextEditor(text: $text, isEditable: isEditable, onSubmit: onSubmit)
        }
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(Color(NSColor.controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .stroke(Color(NSColor.separatorColor), lineWidth: 0.5)
        )
    }
}
