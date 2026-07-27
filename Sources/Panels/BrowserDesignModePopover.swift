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
    @State private var tokenFieldHeight: CGFloat = BrowserDesignModeTokenStyle.singleLineFieldHeight

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Single line: everything inline, vertically centered.
            // Overflowing prompt: the field takes the full width and the
            // controls drop to their own bottom row, like Cursor. The field
            // is always present — an emptied prompt keeps the composer open.
            let field = BrowserDesignModeTokenField(
                controller: controller,
                selections: controller.snapshot?.selections ?? [],
                resetGeneration: controller.promptResetGeneration,
                onHeightChange: { height in
                    if abs(height - tokenFieldHeight) > 0.5 { tokenFieldHeight = height }
                }
            )
            // The card grows downward with the prompt; the inner scroll
            // viewport only engages past this generous ceiling.
            .frame(height: min(max(tokenFieldHeight, BrowserDesignModeTokenStyle.singleLineFieldHeight), 340))
            // ONE layout for every prompt size (a state-dependent layout
            // switch caused a re-wrap livelock): the mode toggle pins to the
            // TOP-LEFT, the copy action overlays the BOTTOM-RIGHT, and the
            // field keeps a constant width between them — vertically centered
            // when single-line, growing straight down as the prompt wraps.
            HStack(alignment: .top, spacing: 10) {
                modeToggle
                field
                    .padding(.top, 2)
                    // Keep the last line clear of the overlaid copy control.
                    .padding(.trailing, 30)
            }
            .overlay(alignment: .bottomTrailing) {
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
    let resetGeneration: UInt
    let onHeightChange: (CGFloat) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(controller: controller, onHeightChange: onHeightChange)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = BrowserDesignModeTokenTextView()
        textView.delegate = context.coordinator
        textView.onHoveredTokenIdentityChanged = { [weak coordinator = context.coordinator] identity in
            coordinator?.hoverToken(identity)
        }
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
        context.coordinator.restoreArchivedPrompt(selections: selections)
        context.coordinator.sync(selections: selections, requestedChange: controller.requestedChange)
        DispatchQueue.main.async {
            textView.window?.makeFirstResponder(textView)
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.applyResetIfNeeded(generation: resetGeneration)
        context.coordinator.sync(selections: selections, requestedChange: controller.requestedChange)
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        if let textView = scrollView.documentView as? BrowserDesignModeTokenTextView {
            textView.onHoveredTokenIdentityChanged = nil
        }
        coordinator.hoverToken(nil)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        private let controller: BrowserDesignModeController
        private let onHeightChange: (CGFloat) -> Void
        weak var textView: BrowserDesignModeTokenTextView?
        private var syncing = false
        var frameObserver: (any NSObjectProtocol)?
        /// Debounces repeated delete actions while the runtime owns the mutation.
        private var removalRequests: Set<String> = []
        private var lastResetGeneration: UInt = 0

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
        /// Wipes the storage when the controller signals a prompt reset
        /// (Escape). requestedChange alone cannot express this because the
        /// field writes storage text back into it after every sync.
        func applyResetIfNeeded(generation: UInt) {
            guard generation != lastResetGeneration else { return }
            lastResetGeneration = generation
            guard let textView, let storage = textView.textStorage, storage.length > 0 else { return }
            syncing = true
            storage.setAttributedString(NSAttributedString(string: "", attributes: typingAttributes))
            syncing = false
            lastIdentities = []
            removalRequests.removeAll()
            controller.requestedChange = ""
            controller.promptRuns = []
            // Runs inside updateNSView; a synchronous @State write would be
            // silently dropped by SwiftUI and the card would stay tall.
            DispatchQueue.main.async { [weak self] in
                self?.reportHeight()
            }
        }

        /// Reconciles the storage with the selection stack incrementally so
        /// tokens stay where the user left them in the prompt: vanished
        /// selections are deleted in place, new selections append at the END
        /// of the existing content ("[pill] text [pill] text"), and the caret
        /// lands after a newly appended token to continue typing.
        func sync(selections: [BrowserDesignModeSelection], requestedChange: String) {
            guard let textView, let storage = textView.textStorage else { return }
            let identities = selections.map(\.selector)
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
            for selection in selections where !present.contains(selection.selector) {
                storage.append(attributedToken(for: selection))
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
            archivePrompt()
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
            // Pin every fragment to the text's rounded natural height:
            // attachment-only rows otherwise lay out 1pt shorter than rows
            // with glyphs, so the first typed character shifted the pills.
            paragraph.minimumLineHeight = BrowserDesignModeTokenStyle.fixedLineHeight
            paragraph.maximumLineHeight = BrowserDesignModeTokenStyle.fixedLineHeight
            paragraph.lineSpacing = 3
            return [
                .font: BrowserDesignModeTokenStyle.font,
                .foregroundColor: NSColor.white.withAlphaComponent(0.96),
                .paragraphStyle: paragraph,
            ]
        }

        /// Plain text follows normal editing semantics immediately. Pills wait
        /// for the authoritative page-runtime mutation before storage changes.
        func textView(
            _ textView: NSTextView,
            shouldChangeTextIn affectedRange: NSRange,
            replacementString: String?
        ) -> Bool {
            guard replacementString?.isEmpty == true,
                  affectedRange.length > 0,
                  let storage = textView.textStorage else { return true }
            let identities = attachmentIdentities(in: storage, range: affectedRange)
            guard !identities.isEmpty else { return true }
            let textRanges = BrowserDesignModeTokenDeletion.textRangesOutsideAttachments(
                in: storage,
                range: affectedRange
            )
            for range in textRanges.reversed() {
                storage.deleteCharacters(in: range)
            }
            if !textRanges.isEmpty {
                textView.setSelectedRange(
                    NSRange(location: min(affectedRange.location, storage.length), length: 0)
                )
                textView.didChangeText()
            }
            for identity in identities {
                requestTokenRemoval(identity: identity)
            }
            return false
        }

        func textDidChange(_ notification: Notification) {
            guard !syncing, let textView else { return }
            let identities = attachmentIdentities(in: textView.textStorage)
            controller.requestedChange = plainText(of: textView.textStorage)
            archivePrompt()
            if identities != lastIdentities {
                // Every supported removal is intercepted before AppKit edits
                // storage. If another mutation path removes a pill, restore
                // it from the authoritative runtime snapshot.
                sync(
                    selections: controller.snapshot?.selections ?? [],
                    requestedChange: controller.requestedChange
                )
                return
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
            // NSTextView maps Escape to complete: (word completion), not
            // cancelOperation:, so both must follow the shared chain: reset
            // the prompt first, exit Design Mode on a clean slate.
            case #selector(NSResponder.cancelOperation(_:)),
                 #selector(NSStandardKeyBindingResponding.complete(_:)):
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
            if let event = NSApp.currentEvent {
                let point = view.convert(event.locationInWindow, from: nil)
                if token.deleteHitRect(in: cellFrame).contains(point) {
                    token.performRemoval()
                    return
                }
            }
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
            let height: CGFloat
            // An emptied prompt snaps back to the original single-line size.
            if textView.textStorage?.length ?? 0 > 0 {
                layoutManager.ensureLayout(for: container)
                var used = layoutManager.usedRect(for: container).height
                // Include the trailing empty line fragment or the caret clips
                // on the final line (same measurement rule as TextBoxInput).
                if layoutManager.extraLineFragmentTextContainer === container {
                    used += layoutManager.extraLineFragmentRect.height
                }
                height = used + textView.textContainerInset.height * 2
            } else {
                height = BrowserDesignModeTokenStyle.singleLineFieldHeight
            }
            // Synchronous on purpose: typing-driven reports (textDidChange)
            // must resize the card in the same event cycle or every wrap
            // paints one frame with the new line clipped. Callers that run
            // inside a SwiftUI update pass defer at their own call site.
            onHeightChange(height)
        }

        private func attachmentIdentities(
            in storage: NSTextStorage?,
            range: NSRange? = nil
        ) -> [String] {
            guard let storage else { return [] }
            var identities: [String] = []
            let enumerationRange = range ?? NSRange(location: 0, length: storage.length)
            storage.enumerateAttribute(.attachment, in: enumerationRange) { value, _, _ in
                if let attachment = value as? BrowserDesignModeTokenAttachment {
                    identities.append(attachment.identity)
                }
            }
            return identities
        }

        /// Snapshots the storage's text/pill order onto the controller,
        /// which outlives this view across pane moves.
        private func archivePrompt() {
            guard let storage = textView?.textStorage else { return }
            var runs: [BrowserDesignModePromptRun] = []
            storage.enumerateAttributes(in: NSRange(location: 0, length: storage.length)) { attrs, range, _ in
                if let attachment = attrs[.attachment] as? BrowserDesignModeTokenAttachment {
                    runs.append(.token(attachment.identity))
                    return
                }
                let piece = (storage.string as NSString).substring(with: range)
                guard !piece.isEmpty else { return }
                if case .text(let previous)? = runs.last {
                    runs[runs.count - 1] = .text(previous + piece)
                } else {
                    runs.append(.text(piece))
                }
            }
            controller.promptRuns = runs
        }

        /// Rebuilds a freshly created (empty) field from the controller's
        /// archived runs so a pane move never loses the typed prompt.
        func restoreArchivedPrompt(selections: [BrowserDesignModeSelection]) {
            guard let textView, let storage = textView.textStorage,
                  storage.length == 0, !controller.promptRuns.isEmpty else { return }
            syncing = true
            for run in controller.promptRuns {
                switch run {
                case .text(let string):
                    storage.append(NSAttributedString(string: string, attributes: typingAttributes))
                case .token(let identity):
                    guard let selection = selections.first(where: { $0.selector == identity }) else { continue }
                    storage.append(attributedToken(for: selection))
                }
            }
            syncing = false
            lastIdentities = attachmentIdentities(in: storage)
            controller.requestedChange = plainText(of: storage)
            textView.setSelectedRange(NSRange(location: storage.length, length: 0))
            DispatchQueue.main.async { [weak self] in
                self?.reportHeight()
            }
        }

        private func plainText(of storage: NSTextStorage?) -> String {
            guard let storage else { return "" }
            let text = storage.string.replacingOccurrences(of: "\u{FFFC}", with: "")
            return String(text.drop(while: { $0 == " " }))
        }

        private func attributedToken(for selection: BrowserDesignModeSelection) -> NSAttributedString {
            BrowserDesignModeTokenAttachment.attributedToken(for: selection) { [weak self] identity in
                self?.requestTokenRemoval(identity: identity)
            }
        }

        private func requestTokenRemoval(identity: String) {
            guard removalRequests.insert(identity).inserted else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                defer { removalRequests.remove(identity) }
                guard let index = controller.snapshot?.selections
                    .firstIndex(where: { $0.selector == identity }) else { return }
                _ = await controller.removeSelection(at: index)
            }
        }

        func hoverToken(_ identity: String?) {
            Task { @MainActor [controller] in
                await controller.setSelectionHover(identity: identity)
            }
        }
    }
}

/// Text view that draws the placeholder after the trailing token when no
/// change text has been typed yet.
final class BrowserDesignModeTokenTextView: NSTextView {
    private var tokenTrackingArea: NSTrackingArea?
    private var hoveredTokenHit: (
        identity: String,
        cell: BrowserDesignModeTokenCell,
        frame: NSRect
    )?
    var onHoveredTokenIdentityChanged: ((String?) -> Void)?
    private(set) var hoveredTokenIdentity: String? {
        didSet {
            guard oldValue != hoveredTokenIdentity else { return }
            needsDisplay = true
            window?.invalidateCursorRects(for: self)
            onHoveredTokenIdentityChanged?(hoveredTokenIdentity)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tokenTrackingArea { removeTrackingArea(tokenTrackingArea) }
        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        tokenTrackingArea = trackingArea
    }

    override func mouseMoved(with event: NSEvent) {
        let previousFrame = hoveredTokenHit?.frame
        let hit = tokenHit(at: convert(event.locationInWindow, from: nil))
        hoveredTokenHit = hit
        if previousFrame != hit?.frame {
            window?.invalidateCursorRects(for: self)
        }
        hoveredTokenIdentity = hit?.identity
        super.mouseMoved(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        hoveredTokenHit = nil
        hoveredTokenIdentity = nil
        super.mouseExited(with: event)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        if let hit = hoveredTokenHit, hit.identity == hoveredTokenIdentity {
            addCursorRect(hit.cell.deleteHitRect(in: hit.frame), cursor: .pointingHand)
        }
    }

    func tokenHit(
        at point: NSPoint
    ) -> (identity: String, cell: BrowserDesignModeTokenCell, frame: NSRect)? {
        guard let storage = textStorage, storage.length > 0,
              let layoutManager, let textContainer else { return nil }
        let origin = textContainerOrigin
        let containerPoint = NSPoint(x: point.x - origin.x, y: point.y - origin.y)
        let glyphIndex = layoutManager.glyphIndex(for: containerPoint, in: textContainer)
        let characterIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)
        guard characterIndex < storage.length,
              let attachment = storage.attribute(
                  .attachment,
                  at: characterIndex,
                  effectiveRange: nil
              ) as? BrowserDesignModeTokenAttachment,
              let cell = attachment.attachmentCell as? BrowserDesignModeTokenCell else { return nil }
        let frame = layoutManager.boundingRect(
            forGlyphRange: NSRange(location: glyphIndex, length: 1),
            in: textContainer
        ).offsetBy(dx: origin.x, dy: origin.y)
        guard frame.insetBy(dx: -2, dy: -2).contains(point) else { return nil }
        return (attachment.identity, cell, frame)
    }

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
        let font = BrowserDesignModeTokenStyle.font
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
            // Fixed-height fragments pin the text baseline at
            // fragmentBottom - descent. Do not use location(forGlyphAt:) here:
            // attachment glyphs report the fragment bottom, not the baseline.
            origin = NSPoint(
                x: textContainerInset.width + location.x + advance + 2,
                y: textContainerInset.height + fragment.maxY + font.descender - font.ascender
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
    /// The font's natural ascent + descent; pills size to exactly this so no
    /// row's fragment ever grows past a plain text row (selection highlights
    /// and the caret then hug the glyphs instead of floating above them).
    static var naturalLineHeight: CGFloat { font.ascender - font.descender }
    /// Every fragment is pinned to this height — the font's rounded natural
    /// line — so rows never resize as pills and glyphs come and go.
    static var fixedLineHeight: CGFloat { ceil(naturalLineHeight) }
    /// Single-line field height: one line plus the 2pt insets.
    static var singleLineFieldHeight: CGFloat { fixedLineHeight + 4 }
}

/// One selection embedded in the prompt text.
final class BrowserDesignModeTokenAttachment: NSTextAttachment {
    let identity: String

    init(
        selection: BrowserDesignModeSelection,
        onRemove: @escaping @MainActor (String) -> Void
    ) {
        identity = selection.selector
        super.init(data: nil, ofType: nil)
        attachmentCell = BrowserDesignModeTokenCell(selection: selection, onRemove: onRemove)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    static func attributedToken(
        for selection: BrowserDesignModeSelection,
        onRemove: @escaping @MainActor (String) -> Void
    ) -> NSAttributedString {
        let token = NSMutableAttributedString(
            attachment: BrowserDesignModeTokenAttachment(selection: selection, onRemove: onRemove)
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
        // Match the field's paragraph so pill rows share text-row metrics.
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = BrowserDesignModeTokenStyle.fixedLineHeight
        paragraph.maximumLineHeight = BrowserDesignModeTokenStyle.fixedLineHeight
        paragraph.lineSpacing = 3
        token.addAttribute(
            .paragraphStyle,
            value: paragraph,
            range: NSRange(location: 0, length: token.length)
        )
        return token
    }
}
