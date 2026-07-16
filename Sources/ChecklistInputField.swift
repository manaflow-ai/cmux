import AppKit
import SwiftUI

/// Native checklist text input used by every checklist add/edit surface.
///
/// Inactive rows stay plain SwiftUI `Text`; only the active add/edit control
/// mounts this AppKit `NSTextView`. That keeps large checklists cheap while
/// preserving normal text-editor behavior for selection, IME, undo, wrapping,
/// and vertical caret movement.
struct ChecklistInputField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let fontSize: CGFloat
    let onCommit: (String) -> Void
    let onCancel: () -> Void
    var textColor: NSColor = .labelColor
    var maxVisibleLines: Int = 8
    var commitsOnFocusLoss: Bool = true
    var selectsAllOnFocus: Bool = false
    var onMoveHighlightWhenEmpty: ((Int) -> Bool)?
    var onToggleHighlightWhenEmpty: (() -> Bool)?
    var onDeleteHighlightWhenEmpty: (() -> Bool)?

    static func visibleLineCount(for text: String, maxLines: Int = 8) -> Int {
        min(max(text.split(separator: "\n", omittingEmptySubsequences: false).count, 1), maxLines)
    }

    static func height(for text: String, fontSize: CGFloat, maxVisibleLines: Int = 8) -> CGFloat {
        let font = NSFont.systemFont(ofSize: fontSize)
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        return CGFloat(visibleLineCount(for: text, maxLines: maxVisibleLines)) * lineHeight + 2
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            text: $text,
            onCommit: onCommit,
            onCancel: onCancel,
            commitsOnFocusLoss: commitsOnFocusLoss,
            onMoveHighlightWhenEmpty: onMoveHighlightWhenEmpty,
            onToggleHighlightWhenEmpty: onToggleHighlightWhenEmpty,
            onDeleteHighlightWhenEmpty: onDeleteHighlightWhenEmpty
        )
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

        let textView = ChecklistInputTextView()
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isEditable = true
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        textView.textColor = textColor
        textView.insertionPointColor = textColor
        textView.font = .systemFont(ofSize: fontSize)
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: scrollView.contentSize.width,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.string = text
        textView.setAccessibilityLabel(placeholder)
        textView.delegate = context.coordinator
        textView.coordinator = context.coordinator
        textView.selectsAllOnFocus = selectsAllOnFocus

        context.coordinator.textView = textView
        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.text = $text
        context.coordinator.onCommit = onCommit
        context.coordinator.onCancel = onCancel
        context.coordinator.commitsOnFocusLoss = commitsOnFocusLoss
        context.coordinator.onMoveHighlightWhenEmpty = onMoveHighlightWhenEmpty
        context.coordinator.onToggleHighlightWhenEmpty = onToggleHighlightWhenEmpty
        context.coordinator.onDeleteHighlightWhenEmpty = onDeleteHighlightWhenEmpty
        context.coordinator.resetIfReusableEmptyField()

        guard let textView = scrollView.documentView as? ChecklistInputTextView else { return }
        textView.font = .systemFont(ofSize: fontSize)
        textView.textColor = textColor
        textView.insertionPointColor = textColor
        textView.setAccessibilityLabel(placeholder)
        textView.selectsAllOnFocus = selectsAllOnFocus
        if textView.string != text {
            textView.string = text
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        var onCommit: (String) -> Void
        var onCancel: () -> Void
        var commitsOnFocusLoss: Bool
        var onMoveHighlightWhenEmpty: ((Int) -> Bool)?
        var onToggleHighlightWhenEmpty: (() -> Bool)?
        var onDeleteHighlightWhenEmpty: (() -> Bool)?
        weak var textView: NSTextView?
        private var finished = false

        init(
            text: Binding<String>,
            onCommit: @escaping (String) -> Void,
            onCancel: @escaping () -> Void,
            commitsOnFocusLoss: Bool,
            onMoveHighlightWhenEmpty: ((Int) -> Bool)?,
            onToggleHighlightWhenEmpty: (() -> Bool)?,
            onDeleteHighlightWhenEmpty: (() -> Bool)?
        ) {
            self.text = text
            self.onCommit = onCommit
            self.onCancel = onCancel
            self.commitsOnFocusLoss = commitsOnFocusLoss
            self.onMoveHighlightWhenEmpty = onMoveHighlightWhenEmpty
            self.onToggleHighlightWhenEmpty = onToggleHighlightWhenEmpty
            self.onDeleteHighlightWhenEmpty = onDeleteHighlightWhenEmpty
        }

        var currentText: String {
            textView?.string ?? text.wrappedValue
        }

        var isEmpty: Bool {
            currentText.isEmpty
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text.wrappedValue = textView.string
        }

        func textDidEndEditing(_ notification: Notification) {
            guard !finished, commitsOnFocusLoss else { return }
            commit()
        }

        func resetIfReusableEmptyField() {
            guard finished, currentText.isEmpty, text.wrappedValue.isEmpty else { return }
            finished = false
        }

        func commit() {
            guard !finished else { return }
            finished = true
            let value = currentText
            text.wrappedValue = value
            onCommit(value)
        }

        func cancel() {
            guard !finished else { return }
            finished = true
            onCancel()
        }
    }
}

final class ChecklistInputTextView: NSTextView {
    weak var coordinator: ChecklistInputField.Coordinator?
    var selectsAllOnFocus = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        window.makeFirstResponder(self)
        if selectsAllOnFocus {
            selectAll(nil)
        } else {
            selectedRange = NSRange(location: string.count, length: 0)
        }
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .function, .numericPad])

        switch event.keyCode {
        case 36, 76:
            if flags == [.shift] {
                insertNewline(nil)
                return
            }
            if flags.isEmpty {
                if coordinator?.isEmpty == true,
                   coordinator?.onToggleHighlightWhenEmpty?() == true {
                    return
                }
                coordinator?.commit()
                return
            }
            if flags == [.command] {
                coordinator?.commit()
                return
            }
        case 53:
            coordinator?.cancel()
            return
        case 51:
            if flags.isEmpty,
               coordinator?.isEmpty == true,
               coordinator?.onDeleteHighlightWhenEmpty?() == true {
                return
            }
        case 126:
            if flags.isEmpty,
               coordinator?.isEmpty == true,
               coordinator?.onMoveHighlightWhenEmpty?(-1) == true {
                return
            }
        case 125:
            if flags.isEmpty,
               coordinator?.isEmpty == true,
               coordinator?.onMoveHighlightWhenEmpty?(1) == true {
                return
            }
        default:
            break
        }

        super.keyDown(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        coordinator?.cancel()
    }
}
