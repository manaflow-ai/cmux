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
    @State private var tokenFieldHeight: CGFloat = 22

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Single line: everything inline, vertically centered.
            // Overflowing prompt: the field takes the full width and the
            // controls drop to their own bottom row, like Cursor. The field
            // is always present — an emptied prompt keeps the composer open.
            let field = BrowserDesignModeTokenField(
                controller: controller,
                selections: controller.snapshot?.selections ?? [],
                onHeightChange: { height in
                    if abs(height - tokenFieldHeight) > 0.5 { tokenFieldHeight = height }
                }
            )
            // The card grows downward with the prompt; the inner scroll
            // viewport only engages past this generous ceiling.
            .frame(height: min(max(tokenFieldHeight, 22), 340))
            // ONE layout for every prompt size: the field keeps a constant
            // width and only grows downward, with the controls riding the
            // bottom edge. Switching between an inline and a stacked layout
            // changed the field width, which re-wrapped the text, which
            // changed the height, which switched the layout back — a SwiftUI
            // livelock (100% CPU) at boundary-length prompts.
            HStack(alignment: .bottom, spacing: 10) {
                modeToggle
                field
                copyButton
            }
            errorMessage
        }
        .padding(10)
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
        .onExitCommand {
            Task { @MainActor in await controller.handleEscape() }
        }
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
            Image(systemName: controller.didCopy ? "checkmark" : "doc.on.clipboard")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(
                    controller.didCopy
                        ? AnyShapeStyle(.green)
                        : AnyShapeStyle(.white.opacity(controller.canCopy ? 0.85 : 0.3))
                )
                // Same 26pt footprint as the mode toggle capsule so the
                // left and right controls sit symmetrically in the card.
                .frame(width: 26, height: 26)
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

    func makeNSView(context: Context) -> NSScrollView {
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
        // Full wrap-and-grow recipe: without the unbounded max size and
        // container height, pills past the first line clip instead of
        // wrapping onto new lines.
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.containerSize = NSSize(
            width: 0,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.widthTracksTextView = true
        textView.setAccessibilityLabel(
            String(
                localized: "browser.designMode.composer.describeChange",
                defaultValue: "Describe the change"
            )
        )
        // The SwiftUI frame caps the field height; content beyond the cap
        // stays reachable through this scroll viewport.
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.verticalScrollElasticity = .none
        scrollView.hasHorizontalScroller = false
        scrollView.documentView = textView
        // contentSize is zero before layout; keep the text view's width (and
        // therefore the wrapping container width) pinned to the scroll
        // view's live content width or lines never wrap.
        scrollView.contentView.postsFrameChangedNotifications = true
        context.coordinator.frameObserver = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification,
            object: scrollView.contentView,
            queue: .main
        ) { [weak textView, weak scrollView] _ in
            MainActor.assumeIsolated {
                guard let textView, let scrollView else { return }
                let width = scrollView.contentView.bounds.width
                guard width > 0, abs(textView.frame.width - width) > 0.5 else { return }
                textView.setFrameSize(NSSize(width: width, height: max(textView.frame.height, 1)))
            }
        }
        context.coordinator.textView = textView
        context.coordinator.sync(selections: selections, requestedChange: controller.requestedChange)
        DispatchQueue.main.async {
            textView.window?.makeFirstResponder(textView)
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.sync(selections: selections, requestedChange: controller.requestedChange)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        private let controller: BrowserDesignModeController
        private let onHeightChange: (CGFloat) -> Void
        weak var textView: BrowserDesignModeTokenTextView?
        private var syncing = false
        var frameObserver: (any NSObjectProtocol)?
        /// Identities the user deleted locally whose page-side removal has
        /// not been confirmed by a snapshot yet. sync() must treat these as
        /// gone, or it would re-append every just-deleted pill and rapid
        /// backspaces would cascade into mass deletions.
        private var pendingRemovals: Set<String> = []

        deinit {
            if let frameObserver {
                NotificationCenter.default.removeObserver(frameObserver)
            }
        }
        private var lastIdentities: [String] = []

        init(controller: BrowserDesignModeController, onHeightChange: @escaping (CGFloat) -> Void) {
            self.controller = controller
            self.onHeightChange = onHeightChange
        }

        /// Rebuilds the token prefix when the selection stack changed,
        /// preserving the typed text and cursor position.
        /// Reconciles the storage with the selection stack incrementally so
        /// tokens stay where the user left them in the prompt: vanished
        /// selections are deleted in place, new selections append at the END
        /// of the existing content ("[pill] text [pill] text"), and the caret
        /// lands after a newly appended token to continue typing.
        func sync(selections: [BrowserDesignModeSelection], requestedChange: String) {
            guard let textView, let storage = textView.textStorage else { return }
            // Snapshots confirm removals by dropping the identity; anything
            // still pending stays masked out of the reconciliation.
            pendingRemovals.formIntersection(selections.map(\.selector))
            let effective = selections.filter { !pendingRemovals.contains($0.selector) }
            let identities = effective.map(\.selector)
            let current = attachmentIdentities(in: storage)
            guard identities.sorted() != current.sorted()
                || plainText(of: storage) != requestedChange else {
                lastIdentities = current
                return
            }
            syncing = true
            defer { syncing = false }

            // Delete tokens whose selections are gone, wherever they sit,
            // absorbing one trailing space so no double gaps remain.
            let wanted = Set(identities)
            var obsolete: [NSRange] = []
            storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
                guard let attachment = value as? BrowserDesignModeTokenAttachment,
                      !wanted.contains(attachment.identity) else { return }
                var expanded = range
                if expanded.upperBound < storage.length,
                   (storage.string as NSString).substring(
                       with: NSRange(location: expanded.upperBound, length: 1)
                   ) == " " {
                    expanded.length += 1
                }
                obsolete.append(expanded)
            }
            for range in obsolete.reversed() {
                storage.deleteCharacters(in: range)
            }

            // Append tokens for newly stacked selections after whatever the
            // user already has. No literal separator characters: the token
            // cell carries its own visual margins, so backspace between
            // pills always deletes a pill, never an invisible space.
            let present = Set(attachmentIdentities(in: storage))
            var appended = false
            for selection in effective where !present.contains(selection.selector) {
                storage.append(BrowserDesignModeTokenAttachment.attributedToken(for: selection, at: 0))
                appended = true
            }

            textView.typingAttributes = typingAttributes
            if appended {
                textView.setSelectedRange(NSRange(location: storage.length, length: 0))
                textView.scrollRangeToVisible(NSRange(location: storage.length, length: 0))
                textView.window?.makeFirstResponder(textView)
            }
            lastIdentities = attachmentIdentities(in: storage)
            controller.requestedChange = plainText(of: storage)
            // sync() runs inside makeNSView/updateNSView; defer the height
            // report so the @State write happens outside SwiftUI's update
            // pass. textDidChange() reports synchronously (AppKit event).
            DispatchQueue.main.async { [weak self] in
                self?.reportHeight()
            }
        }

        private var typingAttributes: [NSAttributedString.Key: Any] {
            // Fixed line metrics tall enough for the 18pt token cells keep
            // wrapped pill rows evenly spaced instead of jumping per line.
            let paragraph = NSMutableParagraphStyle()
            paragraph.minimumLineHeight = 20
            paragraph.lineSpacing = 3
            return [
                .font: BrowserDesignModeTokenStyle.font,
                .foregroundColor: NSColor.white.withAlphaComponent(0.96),
                .paragraphStyle: paragraph,
            ]
        }

        /// A deletion that removes a pill also absorbs the pill's trailing
        /// separator space; otherwise every removed token strands one space
        /// and the prompt accumulates gaps.
        func textView(
            _ textView: NSTextView,
            shouldChangeTextIn affectedRange: NSRange,
            replacementString: String?
        ) -> Bool {
            guard replacementString?.isEmpty == true,
                  affectedRange.length > 0,
                  let storage = textView.textStorage else { return true }
            let content = storage.string as NSString
            guard content.substring(with: affectedRange).contains("\u{FFFC}") else { return true }
            var expanded = affectedRange
            if expanded.upperBound < content.length,
               content.character(at: expanded.upperBound) == 0x20 {
                expanded.length += 1
            }
            guard expanded != affectedRange else { return true }
            storage.deleteCharacters(in: expanded)
            textView.setSelectedRange(NSRange(location: expanded.location, length: 0))
            textView.didChangeText()
            return false
        }

        func textDidChange(_ notification: Notification) {
            guard !syncing, let textView else { return }
            let identities = attachmentIdentities(in: textView.textStorage)
            controller.requestedChange = plainText(of: textView.textStorage)
            if identities != lastIdentities {
                // Tokens were deleted through editing. Storage order can
                // diverge from the runtime's click order (tokens may be
                // moved around in the text), so map each removed identity to
                // its index in the controller's selections, highest first.
                var remaining = identities
                var removedIdentities: [String] = []
                for identity in lastIdentities {
                    if let position = remaining.firstIndex(of: identity) {
                        remaining.remove(at: position)
                    } else {
                        removedIdentities.append(identity)
                    }
                }
                lastIdentities = identities
                pendingRemovals.formUnion(removedIdentities)
                let toRemove = removedIdentities
                Task { @MainActor [controller] in
                    // Resolve each index at removal time: every removal
                    // shifts the indices of the remaining selections.
                    for identity in toRemove {
                        guard let index = controller.snapshot?.selections
                            .firstIndex(where: { $0.selector == identity }) else { continue }
                        await controller.removeSelection(at: index)
                    }
                }
            }
            reportHeight()
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.insertNewline(_:)):
                // Cursor semantics: Enter copies; Shift/Option+Enter types a
                // newline (long text wraps automatically either way).
                if let event = NSApp.currentEvent,
                   !event.modifierFlags.intersection([.shift, .option]).isEmpty {
                    return false
                }
                Task { @MainActor [controller] in await controller.copySelection() }
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                // Escape in the field follows the shared chain: reset the
                // prompt first, exit Design Mode on a clean slate.
                Task { @MainActor [controller] in await controller.handleEscape() }
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
            guard let token = cell as? BrowserDesignModeTokenCell,
                  let selections = controller.snapshot?.selections,
                  let position = selections.firstIndex(where: { $0.selector == token.identity })
            else { return }
            // The XPath is the element's copyable identity: clicking a pill
            // puts the full path on the clipboard and flashes the element.
            let selection = selections[position]
            let identity = selection.xpath.isEmpty ? selection.selector : selection.xpath
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(identity, forType: .string)
            Task { @MainActor [controller] in await controller.revealSelection(at: position) }
        }

        private func reportHeight() {
            guard let textView,
                  let layoutManager = textView.layoutManager,
                  let container = textView.textContainer else { return }
            // An emptied prompt snaps back to the original single-line size.
            guard textView.textStorage?.length ?? 0 > 0 else {
                onHeightChange(22)
                return
            }
            layoutManager.ensureLayout(for: container)
            var height = layoutManager.usedRect(for: container).height
            // Include the trailing empty line fragment or the caret clips on
            // the final line (same measurement rule as TextBoxInput).
            if layoutManager.extraLineFragmentTextContainer === container {
                height += layoutManager.extraLineFragmentRect.height
            }
            onHeightChange(height + textView.textContainerInset.height * 2)
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
            let text = storage.string.replacingOccurrences(of: "\u{FFFC}", with: "")
            return String(text.drop(while: { $0 == " " }))
        }
    }
}

/// Text view that draws the placeholder after the trailing token when no
/// change text has been typed yet.
final class BrowserDesignModeTokenTextView: NSTextView {
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let storage = textStorage,
              storage.string.replacingOccurrences(of: "\u{FFFC}", with: "")
                  .trimmingCharacters(in: .whitespaces).isEmpty,
              let layoutManager, let textContainer else { return }
        let placeholder = String(
            localized: "browser.designMode.composer.describeChange",
            defaultValue: "Describe the change"
        )
        // Anchor after the last VISIBLE glyph (skipping trailing whitespace
        // and newlines left by edits) so the hint hugs the trailing token
        // instead of floating after stale separators.
        var origin = NSPoint(x: textContainerInset.width, y: textContainerInset.height)
        let content = storage.string as NSString
        var lastCharacter = content.length - 1
        while lastCharacter >= 0,
              let scalar = Unicode.Scalar(content.character(at: lastCharacter)),
              CharacterSet.whitespacesAndNewlines.contains(scalar) {
            lastCharacter -= 1
        }
        if lastCharacter >= 0 {
            let lastGlyph = layoutManager.glyphIndexForCharacter(at: lastCharacter)
            let fragment = layoutManager.lineFragmentRect(forGlyphAt: lastGlyph, effectiveRange: nil)
            let location = layoutManager.location(forGlyphAt: lastGlyph)
            let advance = layoutManager.boundingRect(
                forGlyphRange: NSRange(location: lastGlyph, length: 1),
                in: textContainer
            ).width
            origin = NSPoint(
                x: textContainerInset.width + location.x + advance + 2,
                y: textContainerInset.height + fragment.minY + 1
            )
        }
        (placeholder as NSString).draw(
            at: origin,
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
        let token = NSMutableAttributedString(
            attachment: BrowserDesignModeTokenAttachment(selection: selection)
        )
        // Hovering a pill shows its (middle-truncated) XPath; clicking the
        // pill copies the full path.
        let identity = selection.xpath.isEmpty ? selection.selector : selection.xpath
        let truncated: String
        if identity.count > 160 {
            truncated = "\(identity.prefix(79))…\(identity.suffix(80))"
        } else {
            truncated = identity
        }
        token.addAttribute(
            .toolTip,
            value: truncated,
            range: NSRange(location: 0, length: token.length)
        )
        // Match the field's line metrics so rows containing pills keep the
        // same fragment height as plain text rows.
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = 20
        paragraph.lineSpacing = 3
        token.addAttribute(
            .paragraphStyle,
            value: paragraph,
            range: NSRange(location: 0, length: token.length)
        )
        return token
    }
}

/// Draws a token as an inline pill: element-kind glyph plus tag name in blue.
final class BrowserDesignModeTokenCell: NSTextAttachmentCell {
    let identity: String
    private let tagTitle: String
    private let icon: NSImage?

    private static let titleAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 12.5, weight: .medium),
        .foregroundColor: BrowserDesignModeTokenStyle.blue,
    ]

    init(selection: BrowserDesignModeSelection) {
        identity = selection.selector
        tagTitle = selection.tagName
        let configuration = NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
        let symbol = NSImage(
            systemSymbolName: BrowserDesignModeTagSymbol.symbol(forTag: selection.tagName),
            accessibilityDescription: selection.tagName
        )?.withSymbolConfiguration(configuration)
        // Tint once; draw(withFrame:in:) runs on every text-view redraw.
        icon = symbol.map { base in
            NSImage(size: base.size, flipped: false) { rect in
                base.draw(in: rect)
                BrowserDesignModeTokenStyle.blue.set()
                rect.fill(using: .sourceAtop)
                return true
            }
        }
        super.init(textCell: "")
        setAccessibilityLabel(selection.tagName)
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("unsupported") }

    private var titleSize: NSSize {
        (tagTitle as NSString).size(withAttributes: Self.titleAttributes)
    }

    override func cellSize() -> NSSize {
        // Width includes the visual breathing room between pills (no literal
        // space characters live in the storage).
        let iconWidth: CGFloat = icon == nil ? 0 : 13
        return NSSize(width: titleSize.width + iconWidth + 16, height: 18)
    }

    override func cellBaselineOffset() -> NSPoint {
        NSPoint(x: 0, y: -4)
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {
        // Cursor-style: plain blue icon + tag name, no pill background.
        var textX = cellFrame.minX + 8
        if let icon {
            let iconRect = NSRect(
                x: textX,
                y: cellFrame.midY - icon.size.height / 2,
                width: icon.size.width,
                height: icon.size.height
            )
            icon.draw(in: iconRect)
            textX = iconRect.maxX + 3
        }
        (tagTitle as NSString).draw(
            at: NSPoint(x: textX, y: cellFrame.midY - titleSize.height / 2),
            withAttributes: Self.titleAttributes
        )
    }
}
