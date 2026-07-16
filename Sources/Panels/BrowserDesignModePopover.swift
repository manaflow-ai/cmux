import AppKit
import CmuxBrowser
import SwiftUI

/// Cursor-style floating composer card for Design Mode.
///
/// Matches Cursor's design-mode composer: a flat dark card with the selected
/// element chips inline ahead of the change-description field, and a footer
/// with the copy shortcut hint and action. Always renders dark, like the
/// selection overlays it accompanies.
struct BrowserDesignModePopover: View {
    @Bindable var controller: BrowserDesignModeController
    @State private var isCloseHovered = false
    @State private var tokenFieldHeight: CGFloat = 22

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let selections = controller.snapshot?.selections, !selections.isEmpty {
                HStack(alignment: .center, spacing: 10) {
                    modeToggle
                    BrowserDesignModeTokenField(
                        controller: controller,
                        selections: selections,
                        onHeightChange: { height in
                            if abs(height - tokenFieldHeight) > 0.5 { tokenFieldHeight = height }
                        }
                    )
                    .frame(height: min(max(tokenFieldHeight, 22), 110))
                    copyButton
                }
                errorMessage
            } else {
                HStack(alignment: .center, spacing: 10) {
                    modeToggle
                    emptyState
                }
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        .frame(width: 420)
        .background(cardBackground)
        .environment(\.colorScheme, .dark)
        .onHover { hovering in
            // The page cannot see the pointer while it is over the native
            // card; clear its hover highlight so no stale target lingers.
            if hovering {
                Task { @MainActor in await controller.clearPageHover() }
            }
        }
        .onExitCommand { controller.dismissComposer() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "browser.designMode.title", defaultValue: "Design Mode"))
    }

    private var cardBackground: some View {
        let shape = RoundedRectangle(cornerRadius: 26, style: .continuous)
        return shape
            .fill(Color(red: 0.110, green: 0.110, blue: 0.118).opacity(0.98))
            .overlay(shape.strokeBorder(Color.white.opacity(0.09), lineWidth: 1))
            .shadow(color: Color.black.opacity(0.35), radius: 14, y: 5)
    }

    /// Switches between the exclusive element-select and draw-capture modes.
    private var modeToggle: some View {
        HStack(spacing: 2) {
            modeButton(
                icon: "cursorarrow",
                mode: .select,
                help: String(localized: "browser.designMode.mode.select", defaultValue: "Select elements")
            )
            modeButton(
                icon: "scribble",
                mode: .draw,
                help: String(localized: "browser.designMode.mode.draw", defaultValue: "Draw a capture area")
            )
        }
        .padding(2)
        .background(Capsule().fill(Color.white.opacity(0.07)))
    }

    private func modeButton(icon: String, mode: BrowserDesignModeInteractionMode, help: String) -> some View {
        Button {
            Task { @MainActor in await controller.setInteractionMode(mode) }
        } label: {
            Image(systemName: icon)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(controller.interactionMode == mode ? Color.white : Color.white.opacity(0.45))
                .frame(width: 22, height: 22)
                .background(
                    Circle().fill(
                        controller.interactionMode == mode
                            ? Color(red: 0.25, green: 0.47, blue: 0.96)
                            : Color.clear
                    )
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .safeHelp(help)
        .accessibilityLabel(help)
        .accessibilityAddTraits(controller.interactionMode == mode ? .isSelected : [])
    }


    @ViewBuilder
    private var errorMessage: some View {
        if let message = controller.errorMessage {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .cmuxFont(size: 11)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Circular trailing action, mirroring the cmux agent composer's send
    /// button and Cursor's compact pill affordance. Shows a checkmark right
    /// after a successful copy.
    private var copyButton: some View {
        Button {
            Task { @MainActor in await controller.copySelection() }
        } label: {
            Image(systemName: controller.didCopy ? "checkmark" : "doc.on.clipboard.fill")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(
                    Circle().fill(
                        controller.canCopy || controller.didCopy
                            ? Color(red: 0.25, green: 0.47, blue: 0.96)
                            : Color.white.opacity(0.12)
                    )
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.return, modifiers: .command)
        .disabled(!controller.canCopy)
        .safeHelp(
            "\(String(localized: "browser.designMode.copy", defaultValue: "Copy")) (\(String(localized: "browser.designMode.copy.shortcut", defaultValue: "⌘↩")))"
        )
        .accessibilityLabel(String(localized: "browser.designMode.copy", defaultValue: "Copy"))
        .accessibilityIdentifier("BrowserDesignModeCopyButton")
    }

    private var emptyState: some View {
        HStack(alignment: .top, spacing: 6) {
            Group {
                if let message = controller.errorMessage {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                } else {
                    Text(
                        String(
                            localized: "browser.designMode.composer.pickElements",
                            defaultValue: "Select one or more elements on the page."
                        )
                    )
                    .foregroundStyle(.white.opacity(0.55))
                }
            }
            .cmuxFont(size: 11)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            closeButton
        }
    }

    private var closeButton: some View {
        Button {
            controller.dismissComposer()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(isCloseHovered ? AnyShapeStyle(.white) : AnyShapeStyle(.white.opacity(0.45)))
                .frame(width: 18, height: 18)
                .background(Circle().fill(isCloseHovered ? Color.white.opacity(0.12) : Color.clear))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { isCloseHovered = $0 }
        .safeHelp(String(localized: "common.close", defaultValue: "Close"))
        .accessibilityLabel(String(localized: "common.close", defaultValue: "Close"))
    }
}

// MARK: - Token field

/// The prompt editor with selections embedded as inline tokens.
///
/// Each selection is an attachment character in the text storage, so tokens
/// live INSIDE the prompt: backspace deletes a token like a character
/// (anywhere, not only when the field is empty), clicking a token flashes its
/// element on the page, and typed text flows around them.
private struct BrowserDesignModeTokenField: NSViewRepresentable {
    let controller: BrowserDesignModeController
    let selections: [BrowserDesignModeSelection]
    let onHeightChange: (CGFloat) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(controller: controller, onHeightChange: onHeightChange)
    }

    func makeNSView(context: Context) -> BrowserDesignModeTokenTextView {
        let textView = BrowserDesignModeTokenTextView()
        textView.delegate = context.coordinator
        textView.drawsBackground = false
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = BrowserDesignModeTokenStyle.font
        textView.textColor = NSColor.white.withAlphaComponent(0.96)
        textView.insertionPointColor = NSColor(calibratedRed: 0.35, green: 0.62, blue: 1.0, alpha: 1)
        textView.textContainerInset = NSSize(width: 0, height: 2)
        textView.textContainer?.lineFragmentPadding = 0
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.setAccessibilityLabel(
            String(
                localized: "browser.designMode.composer.describeChange",
                defaultValue: "Describe the change"
            )
        )
        context.coordinator.textView = textView
        context.coordinator.sync(selections: selections, requestedChange: controller.requestedChange)
        DispatchQueue.main.async {
            textView.window?.makeFirstResponder(textView)
        }
        return textView
    }

    func updateNSView(_ textView: BrowserDesignModeTokenTextView, context: Context) {
        context.coordinator.sync(selections: selections, requestedChange: controller.requestedChange)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        private let controller: BrowserDesignModeController
        private let onHeightChange: (CGFloat) -> Void
        weak var textView: BrowserDesignModeTokenTextView?
        private var syncing = false
        private var lastIdentities: [String] = []

        init(controller: BrowserDesignModeController, onHeightChange: @escaping (CGFloat) -> Void) {
            self.controller = controller
            self.onHeightChange = onHeightChange
        }

        /// Rebuilds the token prefix when the selection stack changed,
        /// preserving the typed text and cursor position.
        func sync(selections: [BrowserDesignModeSelection], requestedChange: String) {
            guard let textView else { return }
            let identities = selections.map(\.selector)
            let current = attachmentIdentities(in: textView.textStorage)
            guard identities != current || plainText(of: textView.textStorage) != requestedChange else {
                lastIdentities = identities
                return
            }
            syncing = true
            defer { syncing = false }
            let composed = NSMutableAttributedString()
            for (index, selection) in selections.enumerated() {
                composed.append(BrowserDesignModeTokenAttachment.attributedToken(for: selection, at: index))
                composed.append(NSAttributedString(string: " ", attributes: typingAttributes))
            }
            composed.append(NSAttributedString(string: requestedChange, attributes: typingAttributes))
            textView.textStorage?.setAttributedString(composed)
            textView.typingAttributes = typingAttributes
            textView.setSelectedRange(NSRange(location: composed.length, length: 0))
            lastIdentities = identities
            if identities != current {
                textView.window?.makeFirstResponder(textView)
            }
            reportHeight()
        }

        private var typingAttributes: [NSAttributedString.Key: Any] {
            [
                .font: BrowserDesignModeTokenStyle.font,
                .foregroundColor: NSColor.white.withAlphaComponent(0.96),
            ]
        }

        func textDidChange(_ notification: Notification) {
            guard !syncing, let textView else { return }
            let identities = attachmentIdentities(in: textView.textStorage)
            controller.requestedChange = plainText(of: textView.textStorage)
            if identities != lastIdentities {
                // Tokens were deleted through editing: remove the matching
                // selections, highest index first.
                var remaining = identities
                var removed: [Int] = []
                for (index, identity) in lastIdentities.enumerated() {
                    if let position = remaining.firstIndex(of: identity) {
                        remaining.remove(at: position)
                    } else {
                        removed.append(index)
                    }
                }
                lastIdentities = identities
                let indexes = removed.sorted(by: >)
                Task { @MainActor [controller] in
                    for index in indexes {
                        await controller.removeSelection(at: index)
                    }
                }
            }
            reportHeight()
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.insertNewline(_:)):
                Task { @MainActor [controller] in await controller.copySelection() }
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                controller.dismissComposer()
                return true
            default:
                return false
            }
        }

        func textView(
            _ view: NSTextView,
            clickedOn cell: any NSTextAttachmentCellProtocol,
            in cellFrame: NSRect,
            at charIndex: Int
        ) {
            guard let token = cell as? BrowserDesignModeTokenCell else { return }
            let identities = attachmentIdentities(in: view.textStorage)
            guard let position = identities.firstIndex(of: token.identity) else { return }
            Task { @MainActor [controller] in await controller.revealSelection(at: position) }
        }

        private func reportHeight() {
            guard let textView,
                  let layoutManager = textView.layoutManager,
                  let container = textView.textContainer else { return }
            layoutManager.ensureLayout(for: container)
            let used = layoutManager.usedRect(for: container)
            onHeightChange(used.height + textView.textContainerInset.height * 2)
        }

        private func attachmentIdentities(in storage: NSTextStorage?) -> [String] {
            guard let storage else { return [] }
            var identities: [String] = []
            storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, _, _ in
                if let attachment = value as? BrowserDesignModeTokenAttachment {
                    identities.append(attachment.identity)
                }
            }
            return identities
        }

        private func plainText(of storage: NSTextStorage?) -> String {
            guard let storage else { return "" }
            let text = storage.string.replacingOccurrences(
                of: String(UnicodeScalar(NSTextAttachment.character)!),
                with: ""
            )
            return text.drop(while: { $0 == " " }).description
        }
    }
}

/// Text view that draws the placeholder and reports intrinsic height.
final class BrowserDesignModeTokenTextView: NSTextView {
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, textStorage?.length == 0 else { return }
        let placeholder = String(
            localized: "browser.designMode.composer.describeChange",
            defaultValue: "Describe the change"
        )
        (placeholder as NSString).draw(
            at: NSPoint(x: textContainerInset.width, y: textContainerInset.height),
            withAttributes: [
                .font: BrowserDesignModeTokenStyle.font,
                .foregroundColor: NSColor.white.withAlphaComponent(0.35),
            ]
        )
    }
}

enum BrowserDesignModeTokenStyle {
    static var font: NSFont { .systemFont(ofSize: 13.5) }
    static let blue = NSColor(calibratedRed: 0.35, green: 0.62, blue: 1.0, alpha: 1)
}

/// One selection embedded in the prompt text.
final class BrowserDesignModeTokenAttachment: NSTextAttachment {
    let identity: String

    init(selection: BrowserDesignModeSelection) {
        identity = selection.selector
        super.init(data: nil, ofType: nil)
        attachmentCell = BrowserDesignModeTokenCell(selection: selection)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    static func attributedToken(for selection: BrowserDesignModeSelection, at index: Int) -> NSAttributedString {
        NSAttributedString(attachment: BrowserDesignModeTokenAttachment(selection: selection))
    }
}

/// Draws a token as an inline pill: element-kind glyph plus tag name in blue.
final class BrowserDesignModeTokenCell: NSTextAttachmentCell {
    let identity: String
    private let title: String
    private let icon: NSImage?

    private static let titleAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 12.5, weight: .medium),
        .foregroundColor: BrowserDesignModeTokenStyle.blue,
    ]

    init(selection: BrowserDesignModeSelection) {
        identity = selection.selector
        title = selection.tagName
        let configuration = NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
        icon = NSImage(
            systemSymbolName: BrowserDesignModeTagSymbol.symbol(forTag: selection.tagName),
            accessibilityDescription: selection.tagName
        )?.withSymbolConfiguration(configuration)
        super.init(textCell: "")
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("unsupported") }

    private var titleSize: NSSize {
        (title as NSString).size(withAttributes: Self.titleAttributes)
    }

    override func cellSize() -> NSSize {
        let iconWidth: CGFloat = icon == nil ? 0 : 13
        return NSSize(width: titleSize.width + iconWidth + 12, height: 18)
    }

    override func cellBaselineOffset() -> NSPoint {
        NSPoint(x: 0, y: -4)
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {
        let background = NSBezierPath(roundedRect: cellFrame, xRadius: 5, yRadius: 5)
        NSColor.white.withAlphaComponent(0.08).setFill()
        background.fill()

        var textX = cellFrame.minX + 6
        if let icon {
            let iconRect = NSRect(
                x: textX,
                y: cellFrame.midY - icon.size.height / 2,
                width: icon.size.width,
                height: icon.size.height
            )
            let tinted = NSImage(size: icon.size, flipped: false) { rect in
                icon.draw(in: rect)
                BrowserDesignModeTokenStyle.blue.set()
                rect.fill(using: .sourceAtop)
                return true
            }
            tinted.draw(in: iconRect)
            textX = iconRect.maxX + 3
        }
        (title as NSString).draw(
            at: NSPoint(x: textX, y: cellFrame.midY - titleSize.height / 2),
            withAttributes: Self.titleAttributes
        )
    }
}
