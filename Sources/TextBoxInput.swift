/*
 TextBoxInput.swift

 Minimal native text input below the terminal.
 Mouse click to position cursor, standard macOS editing, Enter to send.

 The terminal's existing focus guards (`firstResponder is NSText` checks in
 GhosttySurfaceScrollView) already skip stealing focus from NSTextView subclasses,
 so no additional focus guard code is needed in upstream files.
*/

import AppKit
import SwiftUI

// MARK: - Layout

private enum Layout {
    static let padding: CGFloat = 6
    static let contentSpacing: CGFloat = 4
    static let sendButtonSize: CGFloat = 16
    static let borderWidth: CGFloat = 1
    static let cornerRadius: CGFloat = 5
    static let borderOpacity: CGFloat = 0.3
    static let focusedBorderOpacity: CGFloat = 0.55
    static let textInset = NSSize(width: 4, height: 4)
    static let minLines: Int = 1
    static let maxLines: Int = 6
    static let lineSpacing: CGFloat = 2
    static let placeholderOpacity: CGFloat = 0.35
}

// MARK: - Submit

private enum TextBoxSubmit {
    static func send(_ text: String, via surface: TerminalSurface) {
        let trimmed = text.trimmingCharacters(in: .newlines)
        if !trimmed.isEmpty {
            surface.sendText(trimmed)
        }
        // Send Return as a separate write so bracket-paste-aware shells
        // (zsh, Claude CLI) execute the pasted text.
        surface.sendText("\r")
    }
}

// MARK: - Container View

struct TextBoxInputContainer: View {
    @Binding var text: String
    let surface: TerminalSurface
    let backgroundColor: NSColor
    let foregroundColor: NSColor
    let font: NSFont
    @State private var textViewHeight: CGFloat = 0

    private var adjustedFont: NSFont {
        NSFont.monospacedSystemFont(
            ofSize: max(1, font.pointSize + 1),
            weight: .regular
        )
    }

    private func heightForLines(_ count: Int) -> CGFloat {
        let lineHeight = adjustedFont.ascender - adjustedFont.descender
            + adjustedFont.leading + Layout.lineSpacing
        return lineHeight * CGFloat(count) + Layout.textInset.height * 2
    }

    var body: some View {
        let minH = heightForLines(Layout.minLines)
        let maxH = heightForLines(Layout.maxLines)
        let clamped = max(minH, min(maxH, textViewHeight))

        HStack(alignment: .bottom, spacing: Layout.contentSpacing) {
            TextBoxInputView(
                text: $text,
                textViewHeight: $textViewHeight,
                font: adjustedFont,
                foregroundColor: foregroundColor,
                backgroundColor: backgroundColor,
                onSubmit: { submit() }
            )
            .frame(height: clamped)

            Button(action: submit) {
                Image(systemName: "paperplane.fill")
                    .font(.system(size: Layout.sendButtonSize))
            }
            .buttonStyle(SendButtonStyle(fg: Color(nsColor: foregroundColor)))
            .help("Send")
        }
        .padding(.horizontal, Layout.padding)
        .padding(.vertical, Layout.padding)
        .background(Color(nsColor: backgroundColor))
    }

    private func submit() {
        TextBoxSubmit.send(text, via: surface)
        text = ""
        textViewHeight = 0
    }
}

// MARK: - NSViewRepresentable

struct TextBoxInputView: NSViewRepresentable {
    @Binding var text: String
    @Binding var textViewHeight: CGFloat
    let font: NSFont
    let foregroundColor: NSColor
    let backgroundColor: NSColor
    let onSubmit: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.borderWidth = Layout.borderWidth
        container.layer?.borderColor = foregroundColor
            .withAlphaComponent(Layout.borderOpacity).cgColor
        container.layer?.cornerRadius = Layout.cornerRadius
        container.layer?.masksToBounds = true

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        let tv = InputTextView()
        tv.isRichText = false
        tv.allowsUndo = true
        tv.isEditable = true
        tv.isSelectable = true
        tv.usesFindPanel = false
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.minSize = NSSize(width: 0, height: 0)
        tv.maxSize = NSSize(width: .greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        tv.textContainerInset = Layout.textInset
        tv.delegate = context.coordinator
        tv.onSubmit = onSubmit

        tv.drawsBackground = false
        tv.insertionPointColor = foregroundColor
        tv.textColor = foregroundColor
        tv.selectedTextAttributes = [
            .backgroundColor: foregroundColor,
            .foregroundColor: backgroundColor.withAlphaComponent(1.0),
        ]
        tv.font = font
        tv.typingAttributes = [
            .font: font,
            .foregroundColor: foregroundColor,
        ]

        if let tc = tv.textContainer {
            tc.widthTracksTextView = true
            tc.containerSize = NSSize(width: 0, height: .greatestFiniteMagnitude)
        }

        scrollView.documentView = tv
        context.coordinator.textView = tv
        context.coordinator.container = container

        container.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: container.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])

        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        guard let scrollView = container.subviews.first as? NSScrollView,
              let tv = scrollView.documentView as? InputTextView else { return }
        context.coordinator.parent = self

        if !tv.hasMarkedText(), tv.string != text {
            tv.string = text
            context.coordinator.recalcHeight(tv)
        }

        tv.onSubmit = onSubmit
        tv.insertionPointColor = foregroundColor
        tv.textColor = foregroundColor
        tv.selectedTextAttributes = [
            .backgroundColor: foregroundColor,
            .foregroundColor: backgroundColor.withAlphaComponent(1.0),
        ]
        tv.typingAttributes = [
            .font: font,
            .foregroundColor: foregroundColor,
        ]

        let focused = tv.window?.firstResponder === tv
        let opacity = focused ? Layout.focusedBorderOpacity : Layout.borderOpacity
        container.layer?.borderColor = foregroundColor
            .withAlphaComponent(opacity).cgColor
    }

    static func dismantleNSView(_ container: NSView, coordinator: Coordinator) {
        guard let scrollView = container.subviews.first as? NSScrollView,
              let tv = scrollView.documentView as? InputTextView else { return }
        tv.undoManager?.removeAllActions(withTarget: tv)
    }

    // MARK: Coordinator

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: TextBoxInputView
        weak var textView: NSTextView?
        weak var container: NSView?

        init(_ parent: TextBoxInputView) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            parent.text = tv.string
            recalcHeight(tv)
        }

        func recalcHeight(_ tv: NSTextView) {
            guard let lm = tv.layoutManager, let tc = tv.textContainer else { return }
            lm.ensureLayout(for: tc)
            let h = lm.usedRect(for: tc).height + tv.textContainerInset.height * 2
            parent.textViewHeight = h
        }
    }
}

// MARK: - InputTextView

final class InputTextView: NSTextView {
    var onSubmit: (() -> Void)?

    deinit { undoManager?.removeAllActions(withTarget: self) }

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }

    override func becomeFirstResponder() -> Bool {
        let r = super.becomeFirstResponder()
        if r { updateBorder(focused: true) }
        return r
    }

    override func resignFirstResponder() -> Bool {
        let r = super.resignFirstResponder()
        if r { updateBorder(focused: false) }
        return r
    }

    private func updateBorder(focused: Bool) {
        guard let sv = superview?.superview else { return }
        let opacity = focused ? Layout.focusedBorderOpacity : Layout.borderOpacity
        sv.layer?.borderColor = (textColor ?? .white)
            .withAlphaComponent(opacity).cgColor
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if string.isEmpty {
            let placeholder = "Commands or prompts here\u{2026}"
            let color = (insertionPointColor ?? .white)
                .withAlphaComponent(Layout.placeholderOpacity)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font ?? NSFont.systemFont(ofSize: 13),
                .foregroundColor: color,
            ]
            let inset = textContainerInset
            let origin = NSPoint(
                x: inset.width + (textContainer?.lineFragmentPadding ?? 0),
                y: inset.height
            )
            NSString(string: placeholder).draw(at: origin, withAttributes: attrs)
        }
    }

    override func doCommand(by selector: Selector) {
        if selector == #selector(NSResponder.insertNewline(_:)) ||
           selector == #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)) {
            let shifted = NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false
            if !shifted {
                onSubmit?()
                return
            }
        }
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            window?.resignFirstResponder()
            return
        }
        super.doCommand(by: selector)
    }
}

// MARK: - Send Button Style

private struct SendButtonStyle: ButtonStyle {
    let fg: Color
    func makeBody(configuration: Configuration) -> some View {
        SendButtonBody(configuration: configuration, fg: fg)
    }
}

private struct SendButtonBody: View {
    let configuration: SendButtonStyle.Configuration
    let fg: Color
    @State private var hovered = false

    private var bgOpacity: Double {
        if configuration.isPressed { return 0.16 }
        if hovered { return 0.08 }
        return 0.0
    }

    var body: some View {
        configuration.label
            .foregroundColor(fg)
            .padding(4)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(fg.opacity(bgOpacity))
            )
            .onHover { hovered = $0 }
            .animation(.easeOut(duration: 0.12), value: hovered)
    }
}
